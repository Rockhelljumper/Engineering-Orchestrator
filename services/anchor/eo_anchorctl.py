#!/usr/bin/env python3
"""eo-anchorctl: operator commands for the eo-anchor admin socket (root only).

  sudo eo-anchorctl status
  sudo eo-anchorctl refusals [--since N]
  sudo eo-anchorctl grant ROOT_ID adopt|accept-rollback [--ttl SECONDS] [--note TEXT]
  sudo eo-anchorctl clear ROOT_ID [--note TEXT]

A grant lets the controller bind one root that has no head (adopt), or drop a
root's head and bind it again (accept-rollback). Grants expire (default 15
minutes, at most one hour) and are used once. Every admin action is recorded in
admin.log on the anchor disk.
"""
import argparse
import json
import socket
import sys

DEFAULT_SOCKET = "/run/eo-anchor-admin/admin.sock"


def call(path, req):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(path)
    s.sendall((json.dumps(req) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--socket", default=DEFAULT_SOCKET)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    r = sub.add_parser("refusals")
    r.add_argument("--since", type=int, default=0)
    g = sub.add_parser("grant")
    g.add_argument("root_id")
    g.add_argument("kind", choices=["adopt", "accept-rollback"])
    g.add_argument("--ttl", type=int, default=900)
    g.add_argument("--note", default="")
    c = sub.add_parser("clear")
    c.add_argument("root_id")
    c.add_argument("--note", default="")
    a = ap.parse_args()
    if a.cmd == "status":
        req = {"op": "status"}
    elif a.cmd == "refusals":
        req = {"op": "refusals", "since": a.since}
    elif a.cmd == "grant":
        req = {"op": "grant", "rootId": a.root_id, "kind": a.kind, "ttlSeconds": a.ttl, "note": a.note}
    else:
        req = {"op": "clear", "rootId": a.root_id, "note": a.note}
    reply = call(a.socket, req)
    print(json.dumps(reply, indent=2))
    return 0 if reply.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
