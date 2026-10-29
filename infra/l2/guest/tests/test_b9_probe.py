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


def eth(src, etype, payload=b""):
    return bytes(6) + bytes.fromhex(src.replace(":", "")) + struct.pack(">H", etype) + payload


def ipv4(proto, src, dst, l4=b""):
    hdr = struct.pack(">BBHHHBBH4s4s", 0x45, 0, 20 + len(l4), 0, 0, 64, proto, 0, socket.inet_aton(src), socket.inet_aton(dst))
    return hdr + l4


HOST_MAC = "00:15:5d:aa:bb:cc"


class ClassifyTests(unittest.TestCase):
    def test_arp_ssh_and_own_frames_are_fine(self):
        self.assertIsNone(b9.classify(eth(HOST_MAC, 0x0806, bytes(28)), HOST_MAC))
        ssh = ipv4(6, "192.168.250.1", "192.168.250.2", struct.pack(">HH", 50000, 22) + bytes(16))
        self.assertIsNone(b9.classify(eth(HOST_MAC, 0x0800, ssh), HOST_MAC))
        self.assertIsNone(b9.classify(eth(b9.INT_MAC, 0x0800, ipv4(1, "192.168.250.2", "192.168.250.1")), HOST_MAC))

    def test_host_reply_that_is_not_ssh_is_host_traffic(self):
        rst = ipv4(6, "192.168.250.1", "192.168.250.2", struct.pack(">HH", 445, 40000) + bytes(16))
        self.assertEqual(b9.classify(eth(HOST_MAC, 0x0800, rst), HOST_MAC)["kind"], "hostTraffic")
        unreach = ipv4(1, "192.168.250.1", "192.168.250.2", bytes(8))
        self.assertEqual(b9.classify(eth(HOST_MAC, 0x0800, unreach), HOST_MAC)["kind"], "hostTraffic")
        self.assertEqual(b9.classify(eth(HOST_MAC, 0x86DD, bytes(40)), HOST_MAC)["kind"], "hostTraffic")

    def test_host_multicast_is_information_and_other_macs_are_foreign(self):
        llmnr = ipv4(17, "192.168.250.1", "224.0.0.252", struct.pack(">HH", 55000, 5355) + bytes(4))
        self.assertEqual(b9.classify(eth(HOST_MAC, 0x0800, llmnr), HOST_MAC)["kind"], "hostQuery")
        nb = ipv4(17, "192.168.250.1", "192.168.250.7", struct.pack(">HH", 137, 137) + bytes(4))
        self.assertEqual(b9.classify(eth(HOST_MAC, 0x0800, nb), HOST_MAC)["kind"], "hostQuery")
        self.assertEqual(b9.classify(eth("02:00:00:00:00:01", 0x0806, bytes(28)), HOST_MAC)["kind"], "foreign")


class AddressTests(unittest.TestCase):
    def test_pick_avoids_host_addresses_and_tiny_prefixes(self):
        self.assertEqual(b9.pick_address("192.168.1.0/24", ["192.168.1.254"]), "192.168.1.253")
        self.assertEqual(b9.pick_address("192.168.1.0/24", []), "192.168.1.254")
        self.assertIsNone(b9.pick_address("10.2.0.2/32", []))
        self.assertIsNone(b9.pick_address("10.2.0.2/31", []))
        self.assertEqual(b9.pick_address("10.2.0.0/30", ["10.2.0.2"]), "10.2.0.1")
        self.assertEqual(b9.pick_address("10.0.0.0/8", []), "10.255.255.254")

    def test_bad_targets(self):
        for ip in ("0.0.0.0", "127.0.0.1", "192.168.250.2"):
            self.assertIsNotNone(b9.bad_target_ip(ip), ip)
        self.assertIsNone(b9.bad_target_ip("192.168.250.1"))


class SpecTests(unittest.TestCase):
    def write(self, doc):
        f = tempfile.NamedTemporaryFile("wb", suffix=".json", delete=False)
        f.write(b"\xef\xbb\xbf" + json.dumps(doc).encode())
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def test_stale_or_bad_targets_file_is_refused(self):
        import datetime
        now = datetime.datetime(2026, 10, 29, 12, tzinfo=datetime.timezone.utc)
        ok = {"generatedAt": "2026-10-29T10:00:00.0000000Z", "positive": [], "negative": [{"name": "h", "ip": "10.0.0.5", "checks": []}]}
        self.assertEqual(b9.load_spec(self.write(ok), 6, now)["negative"][0]["ip"], "10.0.0.5")
        with self.assertRaises(SystemExit):
            b9.load_spec(self.write(dict(ok, generatedAt="2026-10-28T10:00:00Z")), 6, now)
        with self.assertRaises(SystemExit):
            b9.load_spec(self.write(dict(ok, positive=[{"name": "LAN gateway", "ip": "0.0.0.0", "checks": []}])), 6, now)


class UdpTests(unittest.TestCase):
    def test_any_udp_answer_is_reachable(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        srv.bind(("127.0.0.1", 0))
        port = srv.getsockname()[1]

        def answer():
            _, addr = srv.recvfrom(2048)
            srv.sendto(b"x", addr)
        threading.Thread(target=answer, daemon=True).start()
        ok, why = b9.udp("127.0.0.1", port)
        srv.close()
        self.assertTrue(ok, why)

    def test_mismatched_dns_id_still_counts(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        srv.bind(("127.0.0.1", 0))

        def answer():
            _, addr = srv.recvfrom(512)
            srv.sendto(struct.pack(">HHHHHH", 0xFFFF, 0x8180, 0, 0, 0, 0), addr)
        threading.Thread(target=answer, daemon=True).start()
        ok, _ = b9.dns("127.0.0.1", srv.getsockname()[1])
        srv.close()
        self.assertTrue(ok)


if __name__ == "__main__":
    r = unittest.main(exit=False, verbosity=2).result
    sys.exit(0 if r.wasSuccessful() else 1)
