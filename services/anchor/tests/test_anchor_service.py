"""B8: the eo-anchor service. Runs the real service on temporary sockets.

python3 -I services/anchor/tests/test_anchor_service.py
Cases that need a second uid (wrong caller, admin from a non-root user) run only
as root and are reported as skipped otherwise.
"""
import hashlib
import json
import os
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SERVICE = os.path.join(HERE, "..", "eo_anchor.py")
CLIENT = os.path.join(HERE, "..", "eo_anchor_client.py")
NOBODY = 65534


def rid():
    return secrets.token_hex(16)


def mac():
    return secrets.token_hex(32)


class Service:
    def __init__(self, log_cap=None, state=None):
        self.tmp = tempfile.mkdtemp(prefix="eo-anchor-test-")
        os.chmod(self.tmp, 0o755)
        self.state = state or os.path.join(self.tmp, "state")
        if not os.path.exists(self.state):
            os.mkdir(self.state, 0o700)
        self.data = os.path.join(self.tmp, "anchor.sock")
        self.admin = os.path.join(self.tmp, "admin.sock")
        self.log_cap = log_cap
        self.start()

    def start(self):
        args = [sys.executable, "-I", SERVICE, "--state-dir", self.state, "--controller-user", str(os.getuid()),
                "--admin-uid", str(os.getuid()), "--data-socket", self.data, "--admin-socket", self.admin]
        if self.log_cap:
            args += ["--log-cap", str(self.log_cap)]
        self.proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        deadline = time.time() + 10
        while not (os.path.exists(self.data) and os.path.exists(self.admin)):
            if self.proc.poll() is not None or time.time() > deadline:
                raise RuntimeError(self.proc.stdout.read().decode())
            time.sleep(0.02)
        if os.getuid() == 0:
            os.chmod(self.data, 0o666)  # let the wrong-uid tests connect, so the service's own check is what refuses
            os.chmod(self.admin, 0o666)

    def stop(self, sig=signal.SIGTERM):
        self.proc.send_signal(sig)
        self.proc.wait(10)
        for p in (self.data, self.admin):
            if os.path.exists(p):
                os.unlink(p)

    def call(self, req, admin=False, as_uid=None):
        path = self.admin if admin else self.data
        if as_uid is None:
            return _call(path, req)
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(r)
            try:
                os.setgid(as_uid)
                os.setuid(as_uid)
                out = json.dumps(_call(path, req)).encode()
            except Exception as e:  # noqa: BLE001
                out = json.dumps({"childError": str(e)}).encode()
            os.write(w, out)
            os._exit(0)
        os.close(w)
        data = b""
        while chunk := os.read(r, 65536):
            data += chunk
        os.waitpid(pid, 0)
        return json.loads(data)


def _call(path, req):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(path)
    s.sendall((json.dumps(req) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        c = s.recv(65536)
        if not c:
            break
        buf += c
    s.close()
    return json.loads(buf)


def adv(root_id, seq, m, prev, key_id=None, root="/srv/eo/root"):
    return {"op": "advance", "rootId": root_id, "keyId": key_id or KEY, "root": root, "seq": seq, "journalMac": m, "prevJournalMac": prev}


KEY = "ab" * 16


class AnchorServiceTests(unittest.TestCase):
    def setUp(self):
        self.svc = Service()

    def tearDown(self):
        if self.svc.proc.poll() is None:
            self.svc.stop()

    def refusals(self):
        return self.svc.call({"op": "refusals"}, admin=True)["records"]

    def chain(self, r, n):
        """Advance root r through n records from genesis; returns the list of MACs."""
        macs, prev = [], "genesis"
        for i in range(1, n + 1):
            m = mac()
            rep = self.svc.call(adv(r, i, m, prev))
            self.assertTrue(rep["ok"], rep)
            macs.append(m)
            prev = m
        return macs

    def assert_refused(self, rep, why):
        self.assertFalse(rep["ok"], rep)
        self.assertTrue(rep.get("refused"), rep)
        self.assertRegex(rep["reason"], why)

    def test_hello_and_empty_read(self):
        h = self.svc.call({"op": "hello"})
        self.assertTrue(h["ok"])
        self.assertRegex(h["anchorId"], "^[0-9a-f]{32}$")
        self.assertIsNone(self.svc.call({"op": "read", "rootId": rid()})["head"])

    def test_forward_chain_and_idempotent_retry(self):
        r = rid()
        macs = self.chain(r, 3)
        head = self.svc.call({"op": "read", "rootId": r})["head"]
        self.assertEqual((head["journalSeq"], head["journalMac"]), (3, macs[2]))
        again = self.svc.call(adv(r, 3, macs[2], macs[1]))
        self.assertTrue(again["ok"])
        self.assertEqual(again["head"]["journalSeq"], 3)
        self.assertEqual(self.refusals(), [])

    def test_backwards_is_refused_logged_and_locks_the_root(self):
        r = rid()
        macs = self.chain(r, 3)
        self.assert_refused(self.svc.call(adv(r, 2, macs[1], macs[0])), "backwards")
        # Locked: even a read and the correct next record are refused now.
        self.assert_refused(self.svc.call({"op": "read", "rootId": r}), "locked")
        self.assert_refused(self.svc.call(adv(r, 4, mac(), macs[2])), "locked")
        recs = self.refusals()
        self.assertEqual(len(recs), 3)
        first = recs[0]
        self.assertEqual(first["peer"]["uid"], os.getuid())
        self.assertGreater(first["peer"]["pid"], 0)
        self.assertEqual(first["request"]["seq"], 2)
        self.assertEqual(first["head"]["journalSeq"], 3)
        self.assertRegex(first["reason"], "backwards")
        # Clearing is an admin action, recorded, and unlocks the root.
        self.assertTrue(self.svc.call({"op": "clear", "rootId": r, "note": "test"}, admin=True)["ok"])
        self.assertTrue(self.svc.call(adv(r, 4, mac(), macs[2]))["ok"])

    def test_skip_conflict_chain_break_and_wrong_key(self):
        cases = [
            (lambda r, m: adv(r, 5, mac(), m[2]), "skip"),
            (lambda r, m: adv(r, 3, mac(), m[1]), "conflicting head"),
            (lambda r, m: adv(r, 4, mac(), mac()), "chain break"),
            (lambda r, m: adv(r, 4, mac(), m[2], key_id="cd" * 16), "journal key"),
        ]
        for make, why in cases:
            with self.subTest(why=why):
                r = rid()
                m = self.chain(r, 3)
                self.assert_refused(self.svc.call(make(r, m)), why)
                head = self.svc.call({"op": "clear", "rootId": r}, admin=True) and self.svc.call({"op": "read", "rootId": r})["head"]
                self.assertEqual(head["journalSeq"], 3, "a refused request must not move the head")

    def test_malformed_requests(self):
        for req, why in [
            ({"op": "advance", "rootId": "nothex"}, "invalid rootId"),
            ({**adv(rid(), 1, mac(), "genesis"), "seq": 0}, "invalid seq"),
            ({**adv(rid(), 1, mac(), "genesis"), "seq": "1"}, "invalid seq"),
            ({**adv(rid(), 1, mac(), "genesis"), "seq": True}, "invalid seq"),
            ({**adv(rid(), 1, "zz", "genesis")}, "invalid journalMac"),
            ({**adv(rid(), 1, mac(), "genesis"), "root": "relative"}, "invalid root"),
            ({"op": "drop-everything", "rootId": rid()}, "unknown op"),
        ]:
            with self.subTest(why=why):
                self.assert_refused(self.svc.call(req), why)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.svc.data)
        s.sendall(b"not json\n")
        rep = json.loads(s.recv(4096))
        s.close()
        self.assert_refused(rep, "not JSON")

    def test_unknown_root_needs_genesis_or_a_grant(self):
        r = rid()
        self.assert_refused(self.svc.call(adv(r, 7, mac(), mac())), "no head")
        self.svc.call({"op": "clear", "rootId": r}, admin=True)
        g = self.svc.call({"op": "grant", "rootId": r, "kind": "adopt", "ttlSeconds": 60}, admin=True)
        self.assertTrue(g["ok"], g)
        self.assertTrue(self.svc.call(adv(r, 7, mac(), mac()))["ok"])
        # Used once: a second root at seq 7 without a grant is refused again.
        r2 = rid()
        self.assert_refused(self.svc.call(adv(r2, 7, mac(), mac())), "no head")

    def test_grant_expires(self):
        r = rid()
        self.assertTrue(self.svc.call({"op": "grant", "rootId": r, "kind": "adopt", "ttlSeconds": 1}, admin=True)["ok"])
        time.sleep(1.2)
        self.assert_refused(self.svc.call(adv(r, 4, mac(), mac())), "no head")

    def test_forget_needs_accept_rollback_grant(self):
        r = rid()
        macs = self.chain(r, 3)
        self.assert_refused(self.svc.call({"op": "forget", "rootId": r}), "accept-rollback")
        self.svc.call({"op": "clear", "rootId": r}, admin=True)
        self.assertTrue(self.svc.call({"op": "grant", "rootId": r, "kind": "accept-rollback", "ttlSeconds": 60}, admin=True)["ok"])
        self.assertTrue(self.svc.call({"op": "forget", "rootId": r})["ok"])
        self.assertIsNone(self.svc.call({"op": "read", "rootId": r})["head"])
        kept = os.listdir(os.path.join(self.svc.state, "forgotten"))
        self.assertEqual(len(kept), 1, "the dropped head is kept")
        self.assertEqual(json.load(open(os.path.join(self.svc.state, "forgotten", kept[0])))["journalMac"], macs[2])
        # The same grant allows exactly one bind of the older journal, then it is spent.
        self.assertTrue(self.svc.call(adv(r, 2, mac(), macs[0]))["ok"])
        self.assert_refused(self.svc.call({"op": "forget", "rootId": r}), "accept-rollback")

    def test_adopt_grant_refused_when_head_exists(self):
        r = rid()
        self.chain(r, 1)
        rep = self.svc.call({"op": "grant", "rootId": r, "kind": "adopt"}, admin=True)
        self.assertFalse(rep["ok"])

    def test_refusal_log_is_hash_chained(self):
        r = rid()
        self.chain(r, 2)
        for _ in range(3):
            self.svc.call(adv(r, 1, mac(), "genesis"))
        lines = open(os.path.join(self.svc.state, "refusals.log"), "rb").read().splitlines()
        prev = "0" * 64
        for line in lines:
            rec = json.loads(line)
            self.assertEqual(rec["prev"], prev)
            prev = hashlib.sha256(line).hexdigest()
        self.assertEqual(len(lines), 3)

    def test_restart_keeps_state_and_rejects_a_broken_chain(self):
        r = rid()
        macs = self.chain(r, 2)
        self.svc.call(adv(r, 1, mac(), "genesis"))  # two refusals
        self.svc.call(adv(r, 1, mac(), "genesis"))
        self.svc.stop()
        self.svc.start()
        self.assertEqual(self.svc.call({"op": "status"}, admin=True)["refusals"], 2)
        self.svc.call({"op": "clear", "rootId": r}, admin=True)
        self.assertTrue(self.svc.call(adv(r, 3, mac(), macs[1]))["ok"])
        self.svc.stop()
        log = os.path.join(self.svc.state, "refusals.log")
        data = open(log, "rb").read()
        # Editing an earlier record breaks the next record's link to it.
        open(log, "wb").write(data.replace(b'"seq":1', b'"seq":1,"x":1', 1))
        with self.assertRaises(RuntimeError):
            self.svc.start()

    def test_torn_refusal_log_tail_is_kept_and_cut(self):
        r = rid()
        self.chain(r, 1)
        self.svc.call(adv(r, 5, mac(), mac()))
        self.svc.stop()
        log = os.path.join(self.svc.state, "refusals.log")
        with open(log, "ab") as f:
            f.write(b'{"seq":2,"partial')
        self.svc.start()
        torn = [f for f in os.listdir(self.svc.state) if f.startswith("refusals.log.torn-")]
        self.assertEqual(len(torn), 1)
        self.svc.call({"op": "clear", "rootId": r}, admin=True)
        self.svc.call(adv(r, 9, mac(), mac()))
        self.assertEqual([x["seq"] for x in self.refusals()], [1, 2])

    def test_fails_closed_when_refusals_cannot_be_recorded(self):
        self.svc.stop()
        self.svc = Service(log_cap=600)
        r = rid()
        macs = self.chain(r, 1)
        for _ in range(5):
            self.svc.call(adv(rid(), 3, mac(), mac()))
        # The log is full, so a refusal could not be recorded: everything is refused now,
        # including a request that would otherwise be valid.
        rep = self.svc.call(adv(r, 2, mac(), macs[0]))
        self.assert_refused(rep, "failing closed")
        self.assertIn("could not record", self.svc.call({"op": "status"}, admin=True)["broken"])

    def test_heads_survive_kill_during_advances(self):
        r = rid()
        prev, seq = "genesis", 0
        for round_ in range(15):
            # Fire requests and kill the service at a random moment in the middle of them.
            pid = os.fork()
            if pid == 0:
                p, s = prev, seq
                try:
                    for _ in range(200):
                        m = mac()
                        rep = _call(self.svc.data, adv(r, s + 1, m, p))
                        if rep.get("ok"):
                            p, s = m, s + 1
                except Exception:  # noqa: BLE001
                    pass
                os._exit(0)
            time.sleep(0.01 + secrets.randbelow(50) / 1000)
            self.svc.stop(signal.SIGKILL)
            os.waitpid(pid, 0)
            self.svc.start()
            head = self.svc.call({"op": "read", "rootId": r})["head"]
            if head is not None:
                self.assertGreaterEqual(head["journalSeq"], seq)
                prev, seq = head["journalMac"], head["journalSeq"]
            leftovers = [f for f in os.listdir(os.path.join(self.svc.state, "heads")) if f.endswith(".tmp")]
            for f in leftovers:  # a kill between write and rename leaves only a temp file
                os.unlink(os.path.join(self.svc.state, "heads", f))
        self.assertGreater(seq, 0)

    @unittest.skipUnless(os.getuid() == 0, "needs root to act as a second uid")
    def test_other_uid_is_refused_on_both_sockets(self):
        r = rid()
        rep = self.svc.call(adv(r, 1, mac(), "genesis"), as_uid=NOBODY)
        self.assert_refused(rep, f"uid {NOBODY} may not use the data socket")
        rep = self.svc.call({"op": "grant", "rootId": r, "kind": "adopt"}, admin=True, as_uid=NOBODY)
        self.assert_refused(rep, f"uid {NOBODY} may not use the admin socket")
        self.assertIsNone(self.svc.call({"op": "read", "rootId": r})["head"])
        self.assertEqual(self.refusals()[0]["peer"]["uid"], NOBODY)

    def test_client_helper_checks_the_server(self):
        rep = subprocess.run([sys.executable, "-I", CLIENT, "--socket", self.svc.data, "--server-user", str(os.getuid())],
                             input=json.dumps({"op": "hello"}), capture_output=True, text=True)
        self.assertEqual(rep.returncode, 0, rep.stdout + rep.stderr)
        self.assertTrue(json.loads(rep.stdout)["ok"])
        if os.getuid() == 0:
            # A socket served by some other uid is not trusted. (Root is always trusted,
            # so this case can only be shown when a non-root user serves it.)
            pass
        rep = subprocess.run([sys.executable, "-I", CLIENT, "--socket", os.path.join(self.svc.tmp, "missing.sock")],
                             input=json.dumps({"op": "hello"}), capture_output=True, text=True)
        self.assertEqual(rep.returncode, 2)


if __name__ == "__main__":
    r = unittest.main(exit=False, verbosity=2).result
    sys.exit(0 if r.wasSuccessful() else 1)
