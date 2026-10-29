"""Self-test for b9-probe.py's probe primitives, on loopback only. Run with python3 -I."""
import importlib.util
import json
import os
import socket
import struct
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("b9probe", os.path.join(HERE, "..", "b9-probe.py"))
b9 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b9)
b9.TIMEOUT = 0.5


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class FakeDns(threading.Thread):
    """Answers one query by echoing its id, like any resolver would."""

    def __init__(self):
        super().__init__(daemon=True)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]

    def run(self):
        data, addr = self.sock.recvfrom(512)
        qid = struct.unpack(">H", data[:2])[0]
        self.sock.sendto(struct.pack(">HHHHHH", qid, 0x8180, 1, 0, 0, 0), addr)


class ProbeTests(unittest.TestCase):
    def test_tcp_listening_is_reachable(self):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        ok, why = b9.tcp("127.0.0.1", srv.getsockname()[1])
        srv.close()
        self.assertTrue(ok, why)

    def test_tcp_refused_counts_as_reachable(self):
        # A RST proves a host answered; B9 must treat it as a leak.
        ok, why = b9.tcp("127.0.0.1", free_port())
        self.assertTrue(ok)
        self.assertIn("refused", why)

    def test_tcp_timeout_and_no_route_are_unreachable(self):
        real = socket.socket.connect
        for exc in (TimeoutError("timed out"), OSError(101, "Network is unreachable"), OSError(1, "Operation not permitted")):
            def fail(sock, addr, exc=exc):
                raise exc
            socket.socket.connect = fail
            try:
                ok, why = b9.tcp("192.0.2.1", 9)
            finally:
                socket.socket.connect = real
            self.assertFalse(ok, why)

    def test_dns_answer_is_reachable(self):
        fake = FakeDns()
        fake.start()
        ok, _ = b9.dns("127.0.0.1", fake.port)
        self.assertTrue(ok)

    def test_dns_silence_is_unreachable(self):
        silent = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        silent.bind(("127.0.0.1", 0))
        try:
            ok, _ = b9.dns("127.0.0.1", silent.getsockname()[1])
        finally:
            silent.close()
        self.assertFalse(ok)

    def test_dns_port_unreachable_counts_as_reachable(self):
        ok, why = b9.dns("127.0.0.1", free_port())
        self.assertTrue(ok, why)

    def test_check_strings_and_bom(self):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]
        doc = {"positive": [{"name": "loop", "ip": "127.0.0.1", "required": True, "checks": [f"tcp/{port}"]}]}
        with tempfile.NamedTemporaryFile("wb", suffix=".json", delete=False) as f:
            f.write(b"\xef\xbb\xbf" + json.dumps(doc).encode())
        loaded = json.load(open(f.name, encoding="utf-8-sig"))
        os.unlink(f.name)
        res = b9.probe_all(loaded["positive"])
        srv.close()
        self.assertEqual(res[0]["check"], f"tcp/{port}")
        self.assertTrue(res[0]["reachable"])


if __name__ == "__main__":
    r = unittest.main(exit=False, verbosity=2).result
    sys.exit(0 if r.wasSuccessful() else 1)
