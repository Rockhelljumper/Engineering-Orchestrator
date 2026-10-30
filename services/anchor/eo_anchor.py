#!/usr/bin/env python3
"""eo-anchor: the rollback-anchor service for the L2 guest (M2 Phase B, R1 and R2).

Runs as the dedicated account eo-anchor and is the only writer of the anchor,
which lives on its own disk (/srv/eo-anchor), outside the state root and outside
every execution snapshot. The controller (account eo) talks to it over a Unix
socket; nothing else can.

Data socket (only the controller's uid, checked with SO_PEERCRED on every
connection):
  hello                      -> anchor id and protocol version
  read     rootId            -> the recorded head, or null
  advance  rootId keyId root seq journalMac prevJournalMac
           accepted only as the exact next record (seq = head + 1 and
           prevJournalMac = the head's MAC), as an exact repeat of the head (a
           retry after a lost reply), as seq 1 from "genesis" for a root never
           seen, or once after an operator's grant for that root.
  forget   rootId            -> only with an operator's accept-rollback grant.
Admin socket (root only): status, grant, clear, refusals.

Every refused request is appended, fsynced and hash-chained to refusals.log on
the anchor disk, with the peer's uid and pid, the request, the stored head and
the reason. A refusal locks that root: later requests for it are refused until
an operator clears it. If a record cannot be written (or the log reached its
size cap) the service refuses everything rather than act unlogged.

Heads use the same JSON shape and MAC as src/anchor.ts, written atomically
(temp file, fsync, rename, directory fsync) before the reply.

Standard library only. Single-threaded: requests are handled one at a time.
"""
import argparse
import datetime
import errno
import hashlib
import hmac
import json
import os
import pwd
import re
import secrets
import select
import socket
import struct
import sys

PROTOCOL = 1
HEX32 = re.compile(r"^[0-9a-f]{32}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
GENESIS = "genesis"
MAX_REQUEST = 8192
MAX_LOG_BYTES = 8 * 1024 * 1024
CONN_TIMEOUT = 2.0
MAX_GRANT_SECONDS = 3600


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_atomic(path, data):
    d = os.path.dirname(path)
    tmp = os.path.join(d, f".{os.path.basename(path)}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.rename(tmp, path)
    fsync_dir(d)


def peer_cred(conn):
    data = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    pid, uid, gid = struct.unpack("3i", data)
    return {"pid": pid, "uid": uid, "gid": gid}


class Refused(Exception):
    pass


class ChainLog:
    """Append-only JSON lines, each carrying the SHA-256 of the line before it."""

    def __init__(self, path, cap):
        self.path = path
        self.cap = cap
        self.prev = "0" * 64
        self.seq = 0
        if os.path.exists(path):
            good = 0
            with open(path, "rb") as f:
                for line in f:
                    if not line.endswith(b"\n"):
                        break  # torn tail from a crash during an append
                    rec = json.loads(line)
                    if rec.get("prev") != self.prev:
                        raise RuntimeError(f"{path}: hash chain broken at seq {rec.get('seq')}")
                    self.prev = hashlib.sha256(line.rstrip(b"\n")).hexdigest()
                    self.seq = rec["seq"]
                    good += len(line)
            if good < os.path.getsize(path):
                # Keep the torn bytes as evidence, then cut them so the chain continues.
                with open(path, "rb") as f:
                    f.seek(good)
                    write_atomic(f"{path}.torn-{now_iso().replace(':', '')}", f.read())
                with open(path, "r+b") as f:
                    f.truncate(good)
                    os.fsync(f.fileno())

    def append(self, body):
        size = os.path.getsize(self.path) if os.path.exists(self.path) else 0
        if size >= self.cap:
            raise OSError(errno.EFBIG, f"{self.path} reached its {self.cap}-byte cap")
        rec = {"seq": self.seq + 1, "ts": now_iso(), "prev": self.prev, **body}
        line = canonical(rec).encode()
        fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, line + b"\n")
            os.fsync(fd)
        finally:
            os.close(fd)
        if size == 0:
            fsync_dir(os.path.dirname(self.path))
        self.prev = hashlib.sha256(line).hexdigest()
        self.seq += 1
        return rec

    def records(self, since=0):
        out = []
        if os.path.exists(self.path):
            with open(self.path, "rb") as f:
                for line in f:
                    if line.endswith(b"\n"):
                        rec = json.loads(line)
                        if rec["seq"] > since:
                            out.append(rec)
        return out


class Anchor:
    def __init__(self, state_dir, log_cap=MAX_LOG_BYTES):
        self.dir = state_dir
        st = os.stat(state_dir)
        if st.st_uid != os.geteuid() or (st.st_mode & 0o077):
            raise RuntimeError(f"{state_dir} must be owned by uid {os.geteuid()} with mode 0700")
        for sub in ("heads", "grants", "forgotten"):
            os.makedirs(os.path.join(state_dir, sub), mode=0o700, exist_ok=True)
        meta = os.path.join(state_dir, "anchor.json")
        if not os.path.exists(meta):
            write_atomic(meta, (canonical({"id": secrets.token_hex(16), "key": secrets.token_hex(32)}) + "\n").encode())
        m = json.load(open(meta))
        if not HEX32.match(m.get("id", "")) or not HEX64.match(m.get("key", "")):
            raise RuntimeError(f"{meta} is malformed")
        self.id = m["id"]
        self.key = bytes.fromhex(m["key"])
        self.refusals = ChainLog(os.path.join(state_dir, "refusals.log"), log_cap)
        self.admin_log = ChainLog(os.path.join(state_dir, "admin.log"), log_cap)
        # Fail closed: once a refusal could not be recorded, nothing more is accepted.
        self.broken = None

    # --- heads -------------------------------------------------------------
    def _head_path(self, root_id):
        return os.path.join(self.dir, "heads", f"{root_id}.json")

    def _mac(self, h):
        body = {k: h[k] for k in ("rootId", "anchorId", "keyId", "root", "journalSeq", "journalMac", "ts")}
        return hmac.new(self.key, canonical(body).encode(), hashlib.sha256).hexdigest()

    def head(self, root_id):
        p = self._head_path(root_id)
        if not os.path.exists(p):
            return None
        h = json.load(open(p))
        if h.get("rootId") != root_id or h.get("anchorId") != self.id or not hmac.compare_digest(h.get("mac", ""), self._mac(h)):
            raise Refused(f"stored head for {root_id} failed verification")
        return h

    def _write_head(self, root_id, key_id, root, seq, mac):
        h = {"rootId": root_id, "anchorId": self.id, "keyId": key_id, "root": root, "journalSeq": seq, "journalMac": mac, "ts": now_iso()}
        h["mac"] = self._mac(h)
        write_atomic(self._head_path(root_id), (json.dumps(h) + "\n").encode())
        return h

    # --- grants and locks ----------------------------------------------------
    def _grant_path(self, root_id):
        return os.path.join(self.dir, "grants", f"{root_id}.json")

    def grant(self, root_id):
        p = self._grant_path(root_id)
        if not os.path.exists(p):
            return None
        g = json.load(open(p))
        if g.get("expires", "") < now_iso():
            return None
        return g

    def _consume_grant(self, root_id, use):
        g = self.grant(root_id)
        g.setdefault("used", []).append(use)
        if g["kind"] == "adopt" or "advance" in g["used"]:
            os.unlink(self._grant_path(root_id))
            fsync_dir(os.path.join(self.dir, "grants"))
        else:
            write_atomic(self._grant_path(root_id), (canonical(g) + "\n").encode())

    def _lock_path(self, root_id):
        return os.path.join(self.dir, "heads", f"{root_id}.locked")

    def locked(self, root_id):
        return os.path.exists(self._lock_path(root_id))

    # --- requests ------------------------------------------------------------
    def handle_data(self, req, peer):
        op = req.get("op")
        if op == "hello":
            return {"ok": True, "anchorId": self.id, "protocol": PROTOCOL}
        root_id = req.get("rootId")
        if not isinstance(root_id, str) or not HEX32.match(root_id):
            raise Refused("invalid rootId")
        if self.locked(root_id):
            raise Refused(f"root {root_id} is locked after an earlier refused request; an operator must clear it")
        if op == "read":
            return {"ok": True, "anchorId": self.id, "head": self.head(root_id)}
        if op == "advance":
            return {"ok": True, "anchorId": self.id, "head": self._advance(root_id, req)}
        if op == "forget":
            return self._forget(root_id, peer)
        raise Refused(f"unknown op {op!r}")

    def _advance(self, root_id, req):
        key_id, root, seq = req.get("keyId"), req.get("root"), req.get("seq")
        mac, prev = req.get("journalMac"), req.get("prevJournalMac")
        if not isinstance(key_id, str) or not HEX32.match(key_id):
            raise Refused("invalid keyId")
        if not isinstance(root, str) or not root.startswith("/") or len(root) > 4096:
            raise Refused("invalid root")
        if type(seq) is not int or seq < 1:
            raise Refused("invalid seq")
        if not isinstance(mac, str) or not HEX64.match(mac):
            raise Refused("invalid journalMac")
        if not isinstance(prev, str) or not (prev == GENESIS or HEX64.match(prev)):
            raise Refused("invalid prevJournalMac")
        cur = self.head(root_id)
        if cur is not None:
            if cur["keyId"] != key_id:
                raise Refused(f"head was recorded under journal key {cur['keyId']}, not {key_id}")
            if seq == cur["journalSeq"]:
                if mac != cur["journalMac"]:
                    raise Refused(f"conflicting head: seq {seq} is anchored with a different MAC")
                return cur
            if seq < cur["journalSeq"]:
                raise Refused(f"backwards: seq {seq} is behind the anchored seq {cur['journalSeq']}")
            if seq > cur["journalSeq"] + 1:
                raise Refused(f"skip: seq {seq} is more than one ahead of the anchored seq {cur['journalSeq']}")
            if prev != cur["journalMac"]:
                raise Refused(f"chain break: seq {seq} does not follow the anchored MAC")
            return self._write_head(root_id, key_id, root, seq, mac)
        g = self.grant(root_id)
        if g is not None:
            h = self._write_head(root_id, key_id, root, seq, mac)
            self._consume_grant(root_id, "advance")
            self.admin_log.append({"event": "grant-used", "rootId": root_id, "kind": g["kind"], "seq": seq})
            return h
        if seq == 1 and prev == GENESIS:
            return self._write_head(root_id, key_id, root, seq, mac)
        raise Refused(f"no head for {root_id} and no operator grant: only seq 1 from genesis is accepted (got seq {seq})")

    def _forget(self, root_id, peer):
        g = self.grant(root_id)
        if g is None or g["kind"] != "accept-rollback" or "forget" in g.get("used", []):
            raise Refused("forget needs an operator's accept-rollback grant")
        p = self._head_path(root_id)
        if os.path.exists(p):
            raw = open(p, "rb").read()
            dest = os.path.join(self.dir, "forgotten", f"{root_id}.{now_iso().replace(':', '')}.json")
            write_atomic(dest, raw)
            os.unlink(p)
            fsync_dir(os.path.join(self.dir, "heads"))
        self._consume_grant(root_id, "forget")
        self.admin_log.append({"event": "forgotten", "rootId": root_id, "peer": peer})
        return {"ok": True, "anchorId": self.id, "head": None}

    def handle_admin(self, req, peer):
        op = req.get("op")
        if op == "status":
            roots = sorted(f[:-5] for f in os.listdir(os.path.join(self.dir, "heads")) if f.endswith(".json"))
            return {"ok": True, "anchorId": self.id, "broken": self.broken,
                    "roots": [{"rootId": r, "head": self.head(r), "locked": self.locked(r), "grant": self.grant(r)} for r in roots],
                    "refusals": self.refusals.seq}
        if op == "refusals":
            return {"ok": True, "records": self.refusals.records(int(req.get("since", 0)))}
        root_id = req.get("rootId")
        if not isinstance(root_id, str) or not HEX32.match(root_id):
            raise Refused("invalid rootId")
        if op == "grant":
            kind = req.get("kind")
            ttl = req.get("ttlSeconds", 900)
            if kind not in ("adopt", "accept-rollback"):
                raise Refused("grant kind must be adopt or accept-rollback")
            if type(ttl) is not int or not 1 <= ttl <= MAX_GRANT_SECONDS:
                raise Refused(f"ttlSeconds must be 1..{MAX_GRANT_SECONDS}")
            if kind == "adopt" and self.head(root_id) is not None:
                raise Refused("root already has a head; use accept-rollback to replace it")
            exp = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=ttl)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
            g = {"rootId": root_id, "kind": kind, "expires": exp, "by": peer, "note": str(req.get("note", ""))[:500]}
            self.admin_log.append({"event": "grant", **g})
            write_atomic(self._grant_path(root_id), (canonical(g) + "\n").encode())
            return {"ok": True, "grant": g}
        if op == "clear":
            self.admin_log.append({"event": "clear", "rootId": root_id, "by": peer, "note": str(req.get("note", ""))[:500]})
            if self.locked(root_id):
                os.unlink(self._lock_path(root_id))
                fsync_dir(os.path.join(self.dir, "heads"))
            return {"ok": True}
        raise Refused(f"unknown admin op {op!r}")

    def refuse(self, channel, req, peer, reason):
        """Record a refusal durably; if that fails, stop accepting anything."""
        root_id = req.get("rootId") if isinstance(req, dict) else None
        head = None
        if isinstance(root_id, str) and HEX32.match(root_id):
            try:
                head = self.head(root_id)
            except Exception as e:  # noqa: BLE001 - a corrupt head is itself evidence
                head = {"error": str(e)}
        try:
            self.refusals.append({"channel": channel, "peer": peer, "request": req, "head": head, "reason": reason})
            if channel == "data" and isinstance(root_id, str) and HEX32.match(root_id) and not self.locked(root_id):
                write_atomic(self._lock_path(root_id), (canonical({"since": now_iso(), "reason": reason}) + "\n").encode())
        except Exception as e:  # noqa: BLE001
            self.broken = f"could not record a refusal: {e}"


def read_request(conn):
    conn.settimeout(CONN_TIMEOUT)
    buf = b""
    while b"\n" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            break
        buf += chunk
        if len(buf) > MAX_REQUEST:
            raise Refused("request too large")
    line = buf.split(b"\n", 1)[0]
    try:
        req = json.loads(line)
    except ValueError:
        raise Refused("request is not JSON") from None
    if not isinstance(req, dict):
        raise Refused("request is not an object")
    return req


def serve_one(anchor, conn, channel, allowed_uid):
    try:
        peer = peer_cred(conn)
        req = {}
        try:
            if peer["uid"] != allowed_uid:
                raise Refused(f"uid {peer['uid']} may not use the {channel} socket")
            req = read_request(conn)
            # Failing closed: only the operator's read-only views still work.
            if anchor.broken and not (channel == "admin" and req.get("op") in ("status", "refusals")):
                raise Refused(f"service is failing closed: {anchor.broken}")
            reply = anchor.handle_data(req, peer) if channel == "data" else anchor.handle_admin(req, peer)
        except Refused as e:
            anchor.refuse(channel, req, peer, str(e))
            reply = {"ok": False, "refused": True, "reason": str(e)}
        except socket.timeout:
            anchor.refuse(channel, req, peer, "timed out reading the request")
            reply = {"ok": False, "refused": True, "reason": "timeout"}
        except Exception as e:  # noqa: BLE001 - never act on a request we could not process
            reply = {"ok": False, "error": f"{type(e).__name__}: {e}"}
        conn.sendall((json.dumps(reply) + "\n").encode())
    except OSError:
        pass
    finally:
        conn.close()


def listen_fds():
    """Sockets passed by systemd socket activation, by FileDescriptorName."""
    if os.environ.get("LISTEN_PID") != str(os.getpid()):
        return {}
    n = int(os.environ.get("LISTEN_FDS", "0"))
    names = os.environ.get("LISTEN_FDNAMES", "").split(":")
    return {names[i]: socket.socket(fileno=3 + i) for i in range(n)}


def bind_unix(path, mode):
    if os.path.exists(path):
        os.unlink(path)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o777 & ~mode)
    try:
        s.bind(path)
    finally:
        os.umask(old)
    s.listen(16)
    return s


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--state-dir", default="/srv/eo-anchor")
    ap.add_argument("--controller-user", default="eo")
    ap.add_argument("--admin-uid", type=int, default=0)
    ap.add_argument("--data-socket", help="bind this path instead of using socket activation (tests)")
    ap.add_argument("--admin-socket", help="bind this path instead of using socket activation (tests)")
    ap.add_argument("--log-cap", type=int, default=MAX_LOG_BYTES)
    a = ap.parse_args(argv)
    controller_uid = pwd.getpwnam(a.controller_user).pw_uid if not a.controller_user.isdigit() else int(a.controller_user)
    anchor = Anchor(a.state_dir, a.log_cap)
    fds = listen_fds()
    data = fds.get("data") or (bind_unix(a.data_socket, 0o660) if a.data_socket else None)
    admin = fds.get("admin") or (bind_unix(a.admin_socket, 0o600) if a.admin_socket else None)
    if data is None or admin is None:
        sys.exit("need both the data and admin sockets (socket activation or --data-socket/--admin-socket)")
    print(f"eo-anchor {anchor.id} serving; controller uid {controller_uid}, admin uid {a.admin_uid}", flush=True)
    channels = {data.fileno(): ("data", data, controller_uid), admin.fileno(): ("admin", admin, a.admin_uid)}
    while True:
        ready, _, _ = select.select([data, admin], [], [])
        for s in ready:
            name, sock, uid = channels[s.fileno()]
            conn, _ = sock.accept()
            serve_one(anchor, conn, name, uid)


if __name__ == "__main__":
    main()
