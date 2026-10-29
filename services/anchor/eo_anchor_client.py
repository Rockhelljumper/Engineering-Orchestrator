#!/usr/bin/env python3
"""One request to an eo-anchor socket: reads a JSON object on stdin, prints the reply.

Used by the controller (src/anchorService.ts), which cannot read a Unix socket
peer's credentials from Node. Before sending, it checks that the socket's owner
is root (systemd socket activation) or the anchor account, so a socket planted
by another user is never trusted. Exit 0 with the reply on stdout; 2 when the
service could not be reached or is not who it should be.
"""
import argparse
import json
import os
import pwd
import socket
import struct
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--server-user", default="eo-anchor")
    ap.add_argument("--timeout", type=float, default=10.0)
    a = ap.parse_args()
    allowed = {0}
    try:
        allowed.add(pwd.getpwnam(a.server_user).pw_uid if not a.server_user.isdigit() else int(a.server_user))
    except KeyError:
        pass
    req = sys.stdin.read()
    json.loads(req)  # refuse to send anything that is not JSON
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(a.timeout)
    try:
        st = os.stat(a.socket)
        if st.st_uid not in allowed:
            print(json.dumps({"ok": False, "error": f"{a.socket} is owned by uid {st.st_uid}, not the anchor service"}))
            return 2
        s.connect(a.socket)
        pid, uid, gid = struct.unpack("3i", s.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        if uid not in allowed:
            print(json.dumps({"ok": False, "error": f"{a.socket} is served by uid {uid}, not the anchor service"}))
            return 2
        s.sendall(req.strip().encode() + b"\n")
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    except OSError as e:
        print(json.dumps({"ok": False, "error": f"cannot reach {a.socket}: {e}"}))
        return 2
    finally:
        s.close()
    sys.stdout.write(buf.decode())
    return 0


if __name__ == "__main__":
    sys.exit(main())
