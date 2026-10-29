#!/usr/bin/env python3
"""B9: installation NIC removed, and no alternate route out of the guest.

Run with python3 -I. Phases:
  setup   positive control, while the setup NIC is attached: the probe must be
          able to reach the Default Switch gateway, the LAN gateway and the
          internet, or a later "unreachable" proves nothing.
  sealed  as root, after guest/20-seal.sh and host 04b: the inventory checks,
          then every target must be unreachable, while a capture on eoint shows
          that the host sent the guest nothing but SSH.
  attack  as root, after "sealed": guest root tries to build a path out.
          The guest firewall is flushed, so only host-side controls remain, and
          every target is retried in three ways:
            route    a default route via 192.168.250.1, from 192.168.250.2;
            spoofed  from /32 addresses of every host-side subnet and from
                     198.51.100.2, through 192.168.250.1, so the host's
                     interface rule is tested without its guest-subnet rule;
            on-link  addresses with the subnet's own prefix on eoint, so a
                     bridge from eo-l2-int to another network would answer.
          It also tries IPv6 and the Hyper-V socket transport (hv_sock) to the
          host's registered services. Everything must fail. The guest's
          addresses, routes and firewall are restored and checked afterwards,
          also on SIGHUP or SIGTERM; reboot the guest after this phase anyway.

Targets come from a JSON file written on the host by host/b9-targets.ps1, at
most --max-age-hours old. Writes a JSON report and exits 0 only when every
expectation holds.
"""
import argparse
import concurrent.futures
import datetime
import errno
import ipaddress
import json
import os
import random
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

INT_IF = "eoint"
INT_MAC = "00:15:5d:e0:02:02"
GUEST_IP = "192.168.250.2"
HOST_IP = "192.168.250.1"
GUEST_NET = ipaddress.ip_network("192.168.250.0/29")
SPOOF_TESTNET = "198.51.100.2"
VMADDR_CID_HOST = 2
AF_VSOCK = 40
TIMEOUT = 3.0
WORKERS = 32


def sh(*cmd, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {r.stderr.strip()}")
    return r


def _err(e):
    return errno.errorcode.get(e.errno, str(e)) if getattr(e, "errno", None) else type(e).__name__


def _sock(kind, source):
    s = socket.socket(socket.AF_INET, kind)
    s.settimeout(TIMEOUT)
    if source:
        s.bind((source, 0))
    return s


def tcp(ip, port, source=None):
    try:
        s = _sock(socket.SOCK_STREAM, source)
    except OSError as e:
        return False, f"bind {source}: {_err(e)}"
    try:
        s.connect((ip, port))
        return True, "connected"
    except ConnectionRefusedError:
        # A RST came back: the host answered, which is reachability.
        return True, "refused (host answered)"
    except OSError as e:
        return False, _err(e)
    finally:
        s.close()


def _dns_query(qid, name="debian.org", qtype=1, flags=0x0100):
    q = struct.pack(">HHHHHH", qid, flags, 1, 0, 0, 0)
    q += b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00"
    return q + struct.pack(">HH", qtype, 1)


def _nbns_query(qid):
    # NetBIOS name query for "*" (wildcard), the shape Windows answers.
    name = b"\x20" + b"CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" + b"\x00"
    return struct.pack(">HHHHHH", qid, 0x0010, 1, 0, 0, 0) + name + struct.pack(">HH", 0x21, 1)


def udp_payload(port):
    qid = random.randrange(65536)
    if port == 53:
        return _dns_query(qid)
    if port == 5353:
        return _dns_query(0, "_services._dns-sd._udp.local", 12, 0)
    if port == 5355:
        return _dns_query(qid, "wpad", 1, 0)
    if port == 137:
        return _nbns_query(qid)
    return b"eo-l2 b9 probe\n"


def udp(ip, port, source=None, payload=None):
    """Reachable when anything answers, or an ICMP port-unreachable comes back."""
    try:
        s = _sock(socket.SOCK_DGRAM, source)
    except OSError as e:
        return False, f"bind {source}: {_err(e)}"
    try:
        # Connected, so an ICMP port-unreachable reply surfaces as an error.
        s.connect((ip, port))
        s.send(payload if payload is not None else udp_payload(port))
        data = s.recv(2048)
        return True, f"answer ({len(data)} bytes)"
    except ConnectionRefusedError:
        return True, "ICMP port unreachable (host answered)"
    except OSError as e:
        return False, _err(e)
    finally:
        s.close()


def dns(ip, port=53, source=None):
    """A DNS query; any reply at all counts as reachable."""
    return udp(ip, port, source, _dns_query(random.randrange(65536)))


def icmp(ip, source=None, broadcast=False):
    cmd = ["ping", "-n", "-c", "1", "-W", "2"] + (["-b"] if broadcast else []) + (["-I", source] if source else []) + [ip]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0, "echo reply" if r.returncode == 0 else (r.stderr.strip() or "no reply")


def run_check(target, check, source=None):
    kind, _, port = check.partition("/")
    port = int(port) if port else 0
    ip = target["ip"]
    if kind == "tcp":
        ok, why = tcp(ip, port, source)
    elif kind == "udp":
        ok, why = udp(ip, port, source)
    elif kind == "udp-dns":
        ok, why = dns(ip, 53, source)
    elif kind == "icmp":
        ok, why = icmp(ip, source, broadcast=(ipaddress.ip_address(ip) == GUEST_NET.broadcast_address))
    else:
        raise ValueError(kind)
    return {"target": target["name"], "ip": ip, "check": check, "source": source or "", "reachable": ok,
            "control": check in target.get("controls", []), "detail": why}


def probe_all(targets, source=None, label=""):
    jobs = [(t, c) for t in targets for c in t["checks"]]
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as ex:
        out = list(ex.map(lambda tc: run_check(tc[0], tc[1], source), jobs))
    for r in out:
        if r["reachable"] or not label:
            print(f"  {'REACHABLE  ' if r['reachable'] else 'unreachable'}  {label}{r['target']:<28} {r['ip']:<16} {r['check']:<10} {r['source']:<15} ({r['detail']})")
    if label:
        print(f"  {label}{len(out)} checks, {sum(r['reachable'] for r in out)} reachable")
    return out


# --- targets file -----------------------------------------------------------

def bad_target_ip(ip):
    """Why an address cannot be a meaningful target, or None."""
    a = ipaddress.ip_address(ip)
    if a.is_unspecified or a.is_loopback:
        return "unspecified or loopback, it would reach the guest itself"
    if str(a) == GUEST_IP:
        return "the guest's own address"
    return None


def load_spec(path, max_age_hours, now=None):
    spec = json.load(open(path, encoding="utf-8-sig"))  # PowerShell 5.1 writes a BOM
    gen = datetime.datetime.fromisoformat(spec["generatedAt"].replace("Z", "+00:00"))
    if gen.tzinfo is None:
        gen = gen.replace(tzinfo=datetime.timezone.utc)
    now = now or datetime.datetime.now(datetime.timezone.utc)
    age = (now - gen).total_seconds() / 3600
    if age > max_age_hours or age < -1:
        raise SystemExit(f"STOP: {path} was generated {age:.1f} h ago (limit {max_age_hours} h); rerun host/b9-targets.ps1 and copy it in")
    for t in spec["positive"] + spec["negative"]:
        why = bad_target_ip(t["ip"])
        if why:
            raise SystemExit(f"STOP: target {t['name']} = {t['ip']} is {why}; fix host/b9-targets.ps1 output")
    return spec


def pick_address(cidr, avoid):
    """An address in cidr that is not the network, broadcast or any address in avoid,
    chosen from the top of the range; None for /31 and /32, which have no spare one."""
    n = ipaddress.ip_network(cidr, strict=False)
    if n.prefixlen >= 31:
        return None
    avoid = {ipaddress.ip_address(a) for a in avoid}
    cand = int(n.broadcast_address) - 1
    for _ in range(64):
        a = ipaddress.ip_address(cand)
        if a in n and a != n.network_address and a not in avoid:
            return str(a)
        cand -= 1
    return None


# --- capture: what the host sends the guest -----------------------------------

ETH_P_ALL = 0x0003
PACKET_OUTGOING = 4


def mac_str(b):
    return ":".join(f"{x:02x}" for x in b)


def classify(frame, host_mac):
    """None for frames that are fine (ARP, SSH, the guest's own); otherwise a dict
    with kind 'foreign' (a MAC that is neither host nor guest), 'hostQuery' (host
    multicast or broadcast, e.g. name lookups) or 'hostTraffic' (anything else the
    host sent the guest: a reply to a probe, or a connection that is not SSH)."""
    if len(frame) < 14:
        return None
    src = mac_str(frame[6:12])
    etype = struct.unpack(">H", frame[12:14])[0]
    off = 14
    if etype == 0x8100 and len(frame) >= 18:
        etype = struct.unpack(">H", frame[16:18])[0]
        off = 18
    if src == INT_MAC:
        return None
    info = {"srcMac": src, "ethertype": f"0x{etype:04x}"}
    if src != host_mac:
        return dict(info, kind="foreign")
    if etype == 0x0806:
        return None
    if etype != 0x0800 or len(frame) < off + 20:
        return dict(info, kind="hostTraffic")
    ihl = (frame[off] & 0x0F) * 4
    proto = frame[off + 9]
    sip = socket.inet_ntoa(frame[off + 12:off + 16])
    dip = socket.inet_ntoa(frame[off + 16:off + 20])
    info.update(proto=proto, src=sip, dst=dip)
    if proto in (6, 17) and len(frame) >= off + ihl + 4:
        sport, dport = struct.unpack(">HH", frame[off + ihl:off + ihl + 4])
        info.update(sport=sport, dport=dport)
        if proto == 6 and (sport == 22 or dport == 22):
            return None
    d = ipaddress.ip_address(dip)
    if d.is_multicast or dip == "255.255.255.255" or d == GUEST_NET.broadcast_address:
        return dict(info, kind="hostQuery")
    return dict(info, kind="hostTraffic")


class Capture(threading.Thread):
    def __init__(self, host_mac):
        super().__init__(daemon=True)
        self.host_mac = host_mac.lower()
        self.sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
        self.sock.bind((INT_IF, 0))
        self.sock.settimeout(0.5)
        self.stop = threading.Event()
        self.frames = 0
        self.arp_from_host = 0
        self.findings = []

    def run(self):
        while not self.stop.is_set():
            try:
                frame, addr = self.sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            if addr[2] == PACKET_OUTGOING:
                continue
            self.frames += 1
            if mac_str(frame[6:12]) == self.host_mac and frame[12:14] == b"\x08\x06":
                self.arp_from_host += 1
            c = classify(frame, self.host_mac)
            if c and len(self.findings) < 500:
                self.findings.append(c)

    def finish(self):
        self.stop.set()
        self.join(timeout=2)
        self.sock.close()
        return {"frames": self.frames, "arpFromHost": self.arp_from_host,
                "hostTraffic": [f for f in self.findings if f["kind"] == "hostTraffic"],
                "foreign": [f for f in self.findings if f["kind"] == "foreign"],
                "hostQueries": [f for f in self.findings if f["kind"] == "hostQuery"]}


# --- inventory --------------------------------------------------------------

def arp_entry(ip):
    for line in open("/proc/net/arp").read().splitlines()[1:]:
        f = line.split()
        if f[0] == ip:
            return f[3].lower(), f[2]
    return None, None


def inventory(spec):
    rows = []

    def row(name, ok, detail=""):
        rows.append({"check": name, "ok": bool(ok), "detail": detail})
        print(f"  {'PASS' if ok else 'FAIL'}  {name}  {detail}")

    ifs = sorted(n for n in os.listdir("/sys/class/net") if n != "lo")
    macs = {n: open(f"/sys/class/net/{n}/address").read().strip() for n in ifs}
    row("exactly one interface besides lo", len(ifs) == 1, ", ".join(f"{n}={m}" for n, m in macs.items()))
    row("that interface is eoint with the expected MAC", ifs == [INT_IF] and macs.get(INT_IF) == INT_MAC)
    routes = [r for r in sh("ip", "-4", "route", "show", "table", "all", check=False).stdout.splitlines()
              if not r.startswith(("local ", "broadcast "))]
    row("routing: only 192.168.250.0/29 on eoint, in any table", routes == ["192.168.250.0/29 dev eoint proto kernel scope link src 192.168.250.2"], " | ".join(routes))
    rules = [r.split(":", 1)[1].strip() for r in sh("ip", "-4", "rule", "show", check=False).stdout.splitlines()]
    row("policy routing: only the three default rules", rules == ["from all lookup local", "from all lookup main", "from all lookup default"], " | ".join(rules))
    row("IPv6 disabled in the kernel", not os.path.exists("/proc/sys/net/ipv6"), "ipv6.disable=1" if not os.path.exists("/proc/sys/net/ipv6") else "IPv6 present")
    addrs = sh("ip", "-4", "-o", "addr", "show", "dev", INT_IF, check=False).stdout.split()
    row("eoint holds only 192.168.250.2/29", [a for a in addrs if "/" in a] == ["192.168.250.2/29"], " ".join(a for a in addrs if "/" in a))
    mac, flags = arp_entry(HOST_IP)
    want = spec.get("hostMac", "").lower()
    row("internal path works: 192.168.250.1 resolves to the host vNIC", mac is not None and flags == "0x2" and (not want or mac == want), f"{mac} flags={flags} expected={want or '?'}")
    wireless = [n for n in ifs if os.path.exists(f"/sys/class/net/{n}/wireless")]
    row("no wireless interfaces", not wireless, ",".join(wireless))
    usb = os.listdir("/sys/bus/usb/devices") if os.path.isdir("/sys/bus/usb/devices") else []
    row("no USB devices", not usb, ",".join(usb))
    bt = os.listdir("/sys/class/bluetooth") if os.path.isdir("/sys/class/bluetooth") else []
    row("no Bluetooth devices", not bt, ",".join(bt))
    row("no /dev/vsock", not os.path.exists("/dev/vsock"))
    try:
        s = socket.socket(AF_VSOCK, socket.SOCK_STREAM)
        s.close()
        row("AF_VSOCK socket cannot be created", False, "created")
    except OSError as e:
        row("AF_VSOCK socket cannot be created", True, _err(e))
    if os.geteuid() == 0:
        for mod in ("hv_sock", "vsock", "vsock_loopback", "bluetooth"):
            r = sh("modprobe", mod, check=False)
            loaded = os.path.isdir(f"/sys/module/{mod}")
            row(f"module {mod} cannot be loaded", r.returncode != 0 and not loaded, (r.stderr.strip() or "loaded")[:80])
        files = sh("find", f"/usr/lib/modules/{os.uname().release}", "-path", "*/net/vmw_vsock/*", "-name", "*.ko*", check=False).stdout.split()
        row("no vsock module files on disk (insmod has nothing to load)", not files, " ".join(files))
    return rows


# --- attack -----------------------------------------------------------------

class Interrupted(Exception):
    pass


def _raise(signum, _frame):
    raise Interrupted(f"signal {signum}")


def guest_net_state():
    return {
        "nft": sh("nft", "list", "ruleset", check=False).stdout,
        "addrs": sh("ip", "-4", "-o", "addr", "show", "dev", INT_IF, check=False).stdout,
        "routes": sh("ip", "-4", "route", "show", "table", "all", check=False).stdout,
    }


def vsock_attack(ports):
    notes, results = [], []
    release = os.uname().release
    files = sh("find", f"/usr/lib/modules/{release}", "-path", "*/net/vmw_vsock/*", "-name", "*.ko*", check=False).stdout.split()
    for mod in ("vsock", "hv_sock"):
        f = next((x for x in files if os.path.basename(x).split(".")[0] == mod), None)
        if not f:
            notes.append(f"insmod {mod}: no module file on disk")
            continue
        r = sh("insmod", f, check=False)
        notes.append(f"insmod {f}: " + ("loaded (unexpected)" if r.returncode == 0 else r.stderr.strip()))
    try:
        s = socket.socket(AF_VSOCK, socket.SOCK_STREAM)
        s.close()
        can = True
    except OSError as e:
        can = False
        notes.append(f"AF_VSOCK socket: {_err(e)}")
    for p in sorted(set(ports) | {22, 80, 443, 2375, 2376, 5000, 6666}):
        if not can:
            results.append({"target": "host hvsocket", "ip": f"vsock:{VMADDR_CID_HOST}", "check": f"vsock/{p}", "source": "", "reachable": False, "control": False, "detail": "no AF_VSOCK"})
            continue
        s = socket.socket(AF_VSOCK, socket.SOCK_STREAM)
        s.settimeout(TIMEOUT)
        try:
            s.connect((VMADDR_CID_HOST, p))
            ok, why = True, "connected"
        except ConnectionRefusedError:
            ok, why = False, "refused (transport present, no service)"
            notes.append(f"vsock/{p}: refused, so the hv_sock transport reached the host")
        except OSError as e:
            ok, why = False, _err(e)
        finally:
            s.close()
        results.append({"target": "host hvsocket", "ip": f"vsock:{VMADDR_CID_HOST}", "check": f"vsock/{p}", "source": "", "reachable": ok or why.startswith("refused"), "control": False, "detail": why})
    for mod in ("hv_sock", "vsock"):
        if os.path.isdir(f"/sys/module/{mod}"):
            sh("rmmod", mod, check=False)
    return results, notes


def attack(spec):
    """Guest root tries to build a path out. Returns (results, notes, restore)."""
    notes, results = [], []
    saved = guest_net_state()
    targets = spec["positive"] + spec["negative"]
    host_targets = [t for t in spec["negative"] if t["name"].startswith("host ")]
    avoid = {t["ip"] for t in targets} | {GUEST_IP, HOST_IP}
    added = []
    old = {s: signal.signal(s, _raise) for s in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT)}

    def add(cidr, why):
        r = sh("ip", "addr", "add", cidr, "dev", INT_IF, check=False)
        if r.returncode == 0:
            added.append(cidr)
            notes.append(f"added {cidr} ({why})")
            return True
        notes.append(f"could not add {cidr}: {r.stderr.strip()}")
        return False

    try:
        sh("nft", "flush", "ruleset")
        notes.append("guest nftables flushed; only host-side controls remain")
        r = sh("sysctl", "-w", "net.ipv6.conf.all.disable_ipv6=0", check=False)
        notes.append("IPv6 re-enable attempt: " + ("succeeded (unexpected)" if r.returncode == 0 else "impossible, " + (r.stderr.strip() or "no ipv6 sysctl")))
        results.append({"target": "IPv6", "ip": "-", "check": "sysctl", "source": "", "reachable": r.returncode == 0, "control": False, "detail": r.stderr.strip()})

        r = sh("ip", "route", "add", "default", "via", HOST_IP, "dev", INT_IF, check=False)
        notes.append("default route via 192.168.250.1 " + ("added" if r.returncode == 0 else f"failed: {r.stderr.strip()}"))
        print("Pass 1, route: default route via the host, from 192.168.250.2")
        results += [dict(x, mode="route") for x in probe_all(targets, label="route: ")]

        print("Pass 2, spoofed: /32 sources outside the guest subnet, through the host")
        sources = [(SPOOF_TESTNET, "TEST-NET-2, matches no host subnet")]
        for net in spec["subnets"]:
            a = pick_address(net["cidr"], avoid)
            if a:
                sources.append((a, f"{net['name']} {net['cidr']}"))
            else:
                notes.append(f"spoofed: no spare address in {net['cidr']} ({net['name']}); skipped")
        for src, why in sources:
            if add(f"{src}/32", f"spoofed source, {why}"):
                results += [dict(x, mode="spoofed") for x in probe_all(host_targets + [{"name": "host eo-l2-int", "ip": HOST_IP, "checks": ["tcp/22", "tcp/445", "udp-dns", "icmp"]}], source=src, label=f"spoofed {src}: ")]

        print("Pass 3, on-link: host-side subnets placed directly on eoint")
        for cidr in list(added):
            sh("ip", "addr", "del", cidr, "dev", INT_IF, check=False)
            added.remove(cidr)
        for net in spec["subnets"]:
            n = ipaddress.ip_network(net["cidr"], strict=False)
            if n.prefixlen >= 30:
                notes.append(f"on-link: {net['cidr']} ({net['name']}) has no spare address; skipped")
                continue
            a = pick_address(net["cidr"], avoid)
            if a:
                add(f"{a}/{n.prefixlen}", f"on-link, {net['name']}")
        results += [dict(x, mode="on-link") for x in probe_all(targets, label="on-link: ")]

        print("Hyper-V socket transport:")
        vres, vnotes = vsock_attack(spec.get("hvsockPorts", []))
        notes += vnotes
        results += [dict(x, mode="hvsock") for x in vres]
        for n in notes:
            print(f"  attack: {n}")
        return results, notes, None
    except Interrupted as e:
        notes.append(f"interrupted by {e}; restoring")
        raise
    finally:
        for s in old:
            signal.signal(s, signal.SIG_IGN)
        sh("ip", "route", "del", "default", "via", HOST_IP, "dev", INT_IF, check=False)
        for cidr in added:
            sh("ip", "addr", "del", cidr, "dev", INT_IF, check=False)
        r = subprocess.run(["nft", "-f", "-"], input="flush ruleset\n" + saved["nft"], text=True, capture_output=True)
        if r.returncode != 0:
            subprocess.run(["systemctl", "restart", "nftables"])
        now = guest_net_state()
        diff = [k for k in saved if saved[k] != now[k]]
        print("  attack: guest addresses, routes and firewall " + ("restored and checked" if not diff else f"NOT restored ({', '.join(diff)}); reboot the guest"))
        attack.restore = {"ok": not diff, "differs": diff}
        for s, h in old.items():
            signal.signal(s, h)


# --- main -------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("phase", choices=["setup", "sealed", "attack"])
    ap.add_argument("--targets", required=True, help="JSON from host/b9-targets.ps1")
    ap.add_argument("--out", required=True, help="report path (.json)")
    ap.add_argument("--max-age-hours", type=float, default=6.0)
    a = ap.parse_args()
    spec = load_spec(a.targets, a.max_age_hours)
    report = {"phase": a.phase, "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "uid": os.geteuid(),
              "targetsGeneratedAt": spec["generatedAt"], "targetsComputer": spec.get("computer")}
    ok = True

    if a.phase == "setup":
        print("Positive control (setup NIC attached):")
        res = probe_all(spec["positive"])
        report["probes"] = res
        need = {r["target"] for r in res if r["reachable"]}
        missing = [t["name"] for t in spec["positive"] if t.get("required") and t["name"] not in need]
        report["missingPositive"] = missing
        ok = not missing
        print("POSITIVE CONTROL " + ("OK" if ok else f"FAILED: not reachable: {missing}"))
    else:
        if os.geteuid() != 0:
            sys.exit(f"the {a.phase} phase needs root (it captures on eoint)")
        if not spec.get("hostMac"):
            sys.exit("STOP: the targets file has no hostMac; rerun host/b9-targets.ps1")
        print("Inventory:")
        inv = inventory(spec)
        report["inventory"] = inv
        cap = Capture(spec["hostMac"])
        cap.start()
        try:
            if a.phase == "sealed":
                print("Targets (all must be unreachable):")
                res = probe_all(spec["positive"] + spec["negative"], label="sealed: ")
            else:
                print("Alternate-adapter attack (all must be unreachable):")
                attack.restore = {"ok": False, "differs": ["not run"]}
                try:
                    res, notes, _ = attack(spec)
                finally:
                    report["restore"] = attack.restore
                report["attackNotes"] = notes
                print("Inventory after restore:")
                report["inventoryAfter"] = inventory(spec)
        finally:
            time.sleep(1)
            report["capture"] = cap.finish()
        c = report["capture"]
        print(f"Capture on eoint: {c['frames']} frames in; {len(c['hostTraffic'])} non-SSH frames from the host; {len(c['foreign'])} from other MACs; {len(c['hostQueries'])} host multicast/broadcast frames (information)")
        for f in c["hostTraffic"][:20] + c["foreign"][:20]:
            print(f"  FRAME {f}")
        report["probes"] = res
        leaks = [r for r in res if r["reachable"]]
        report["leaks"] = leaks
        controls = [r for r in res if r["control"]]
        report["controlChecks"] = len(controls)
        print(f"Checks on ports another host rule allows (unreachable only because of the eo-l2 rules): {len(controls)}")
        ok = (all(r["ok"] for r in inv) and not leaks and not c["hostTraffic"] and not c["foreign"]
              and (a.phase == "sealed" or (report["restore"]["ok"] and all(r["ok"] for r in report["inventoryAfter"]))))
        print(("B9 " + a.phase.upper() + " PASSED") if ok else f"B9 {a.phase.upper()} FAILED: {len(leaks)} reachable, inventory ok={all(r['ok'] for r in inv)}, host frames={len(c['hostTraffic'])}, foreign frames={len(c['foreign'])}")

    report["passed"] = ok
    with open(a.out, "w") as f:
        json.dump(report, f, indent=2)
    print(f"report: {a.out}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
