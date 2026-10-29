#!/usr/bin/env python3
"""B9: installation NIC removed, and no alternate route out of the guest.

Run with python3 -I. Phases:
  setup   positive control, while the setup NIC is attached: the probe must be
          able to reach the Default Switch gateway, the LAN gateway and the
          internet, or a later "unreachable" proves nothing.
  sealed  after guest/20-seal.sh and host 04b: the inventory checks, then every
          target must be unreachable.
  attack  as root, after "sealed": flush the guest firewall, add addresses from
          every host-side subnet (LAN, Default Switch, WSL, VirtualBox host-only,
          VPN) to the only interface, add a default route via 192.168.250.1, and
          retry every target. Everything must still fail, which shows the host
          neither forwards nor answers. The guest firewall and addresses are
          restored afterwards, even on error.

Targets come from a JSON file written on the host by host/b9-targets.ps1.
Writes a JSON report next to the human-readable output and exits 0 only when
every expectation holds.
"""
import argparse
import errno
import ipaddress
import json
import os
import random
import socket
import struct
import subprocess
import sys
import time

INT_MAC = "00:15:5d:e0:02:02"
GUEST_IP = "192.168.250.2"
HOST_IP = "192.168.250.1"
TIMEOUT = 3.0


def sh(*cmd, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {r.stderr.strip()}")
    return r


def tcp(ip, port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    try:
        s.connect((ip, port))
        return True, "connected"
    except ConnectionRefusedError:
        # A RST came back: the host answered, which is reachability.
        return True, "refused (host answered)"
    except OSError as e:
        return False, errno.errorcode.get(e.errno, str(e)) if e.errno else type(e).__name__
    finally:
        s.close()


def dns(ip, port=53):
    qid = random.randrange(65536)
    q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    q += b"".join(bytes([len(p)]) + p.encode() for p in "debian.org".split(".")) + b"\x00"
    q += struct.pack(">HH", 1, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(TIMEOUT)
    try:
        # Connected, so an ICMP port-unreachable reply surfaces as an error.
        s.connect((ip, port))
        s.send(q)
        data = s.recv(512)
        return (len(data) >= 2 and struct.unpack(">H", data[:2])[0] == qid), "answer"
    except ConnectionRefusedError:
        # ICMP port unreachable came back: the host answered.
        return True, "ICMP port unreachable (host answered)"
    except OSError as e:
        return False, errno.errorcode.get(e.errno, str(e)) if e.errno else type(e).__name__
    finally:
        s.close()


def icmp(ip):
    r = subprocess.run(["ping", "-n", "-c", "1", "-W", "2", ip], capture_output=True, text=True)
    return r.returncode == 0, "echo reply" if r.returncode == 0 else (r.stderr.strip() or "no reply")


def probe_all(targets):
    out = []
    for t in targets:
        for check in t["checks"]:
            kind, _, port = check.partition("/")
            port = int(port) if port else 0
            if kind == "tcp":
                ok, why = tcp(t["ip"], port)
            elif kind == "udp-dns":
                ok, why = dns(t["ip"])
            elif kind == "icmp":
                ok, why = icmp(t["ip"])
            else:
                raise ValueError(kind)
            out.append({"target": t["name"], "ip": t["ip"], "check": f"{kind}/{port}" if port else kind, "reachable": ok, "detail": why})
            print(f"  {'REACHABLE  ' if ok else 'unreachable'}  {t['name']:<28} {t['ip']:<16} {kind}/{port or '-'}  ({why})")
    return out


def inventory():
    rows = []

    def row(name, ok, detail=""):
        rows.append({"check": name, "ok": bool(ok), "detail": detail})
        print(f"  {'PASS' if ok else 'FAIL'}  {name}  {detail}")

    ifs = sorted(n for n in os.listdir("/sys/class/net") if n != "lo")
    macs = {n: open(f"/sys/class/net/{n}/address").read().strip() for n in ifs}
    row("exactly one interface besides lo", len(ifs) == 1, ", ".join(f"{n}={m}" for n, m in macs.items()))
    row("that interface is eoint with the expected MAC", ifs == ["eoint"] and macs.get("eoint") == INT_MAC)
    v4 = sh("ip", "-4", "route", "show", "default", check=False).stdout.strip()
    row("no IPv4 default route", v4 == "", v4)
    row("IPv6 disabled in the kernel", not os.path.exists("/proc/sys/net/ipv6"), "ipv6.disable=1" if not os.path.exists("/proc/sys/net/ipv6") else "IPv6 present")
    addrs = sh("ip", "-4", "-o", "addr", "show", "dev", "eoint", check=False).stdout.split()
    row("eoint holds only 192.168.250.2/29", [a for a in addrs if "/" in a] == ["192.168.250.2/29"], " ".join(a for a in addrs if "/" in a))
    wireless = [n for n in ifs if os.path.exists(f"/sys/class/net/{n}/wireless")]
    row("no wireless interfaces", not wireless, ",".join(wireless))
    usb = [d for d in os.listdir("/sys/bus/usb/devices")] if os.path.isdir("/sys/bus/usb/devices") else []
    row("no USB devices", not usb, ",".join(usb))
    bt = os.listdir("/sys/class/bluetooth") if os.path.isdir("/sys/class/bluetooth") else []
    row("no Bluetooth devices", not bt, ",".join(bt))
    row("no /dev/vsock", not os.path.exists("/dev/vsock"))
    try:
        s = socket.socket(40, socket.SOCK_STREAM)  # AF_VSOCK
        s.close()
        row("AF_VSOCK socket cannot be created", False, "created")
    except OSError as e:
        row("AF_VSOCK socket cannot be created", True, errno.errorcode.get(e.errno, str(e)))
    if os.geteuid() == 0:
        for mod in ("hv_sock", "vsock", "vsock_loopback", "bluetooth"):
            r = sh("modprobe", mod, check=False)
            loaded = os.path.isdir(f"/sys/module/{mod}")
            row(f"module {mod} cannot be loaded", r.returncode != 0 and not loaded, (r.stderr.strip() or "loaded")[:80])
    return rows


def attack(targets, subnets):
    """Guest root tries to build a path out. Returns (results, notes)."""
    notes = []
    added = []
    nft_saved = sh("nft", "list", "ruleset").stdout
    try:
        sh("nft", "flush", "ruleset")
        notes.append("guest nftables flushed; only host-side controls remain")
        for net in subnets:
            n = ipaddress.ip_network(net["cidr"], strict=False)
            hosts = list(n.hosts())
            # An address near the top of the range, unlikely to collide with a real host.
            pick = hosts[-2] if len(hosts) > 2 else hosts[0]
            cidr = f"{pick}/{n.prefixlen}"
            r = sh("ip", "addr", "add", cidr, "dev", "eoint", check=False)
            if r.returncode == 0:
                added.append(cidr)
                notes.append(f"added {cidr} ({net['name']})")
            else:
                notes.append(f"could not add {cidr}: {r.stderr.strip()}")
        sh("ip", "link", "set", "eoint", "up")
        r = sh("ip", "route", "add", "default", "via", HOST_IP, "dev", "eoint", check=False)
        notes.append("default route via 192.168.250.1 " + ("added" if r.returncode == 0 else f"failed: {r.stderr.strip()}"))
        # IPv6 cannot be re-enabled at runtime when the kernel booted with ipv6.disable=1.
        r = sh("sysctl", "-w", "net.ipv6.conf.all.disable_ipv6=0", check=False)
        notes.append("IPv6 re-enable attempt: " + ("succeeded (unexpected)" if r.returncode == 0 else "impossible, " + (r.stderr.strip() or "no ipv6 sysctl")))
        for n in notes:
            print(f"  attack: {n}")
        results = probe_all(targets)
        return results, notes
    finally:
        sh("ip", "route", "del", "default", "via", HOST_IP, "dev", "eoint", check=False)
        for cidr in added:
            sh("ip", "addr", "del", cidr, "dev", "eoint", check=False)
        r = subprocess.run(["nft", "-f", "-"], input=nft_saved, text=True, capture_output=True)
        if r.returncode != 0:
            subprocess.run(["systemctl", "restart", "nftables"])
        print("  attack: guest addresses, route and firewall restored")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("phase", choices=["setup", "sealed", "attack"])
    ap.add_argument("--targets", required=True, help="JSON from host/b9-targets.ps1")
    ap.add_argument("--out", required=True, help="report path (.json)")
    a = ap.parse_args()
    spec = json.load(open(a.targets, encoding="utf-8-sig"))  # PowerShell 5.1 writes a BOM
    report = {"phase": a.phase, "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "uid": os.geteuid()}
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
        print("Inventory:")
        inv = inventory()
        report["inventory"] = inv
        ok = all(r["ok"] for r in inv)
        targets = spec["positive"] + spec["negative"]
        if a.phase == "sealed":
            print("Targets (all must be unreachable):")
            res = probe_all(targets)
        else:
            if os.geteuid() != 0:
                sys.exit("attack phase needs root")
            print("Alternate-adapter attack (all must be unreachable):")
            res, notes = attack(targets, spec["subnets"])
            report["attackNotes"] = notes
        report["probes"] = res
        leaks = [r for r in res if r["reachable"]]
        report["leaks"] = leaks
        ok = ok and not leaks
        print(("B9 " + a.phase.upper() + " PASSED") if ok else f"B9 {a.phase.upper()} FAILED: {len(leaks)} reachable, inventory ok={all(r['ok'] for r in inv)}")

    report["passed"] = ok
    with open(a.out, "w") as f:
        json.dump(report, f, indent=2)
    print(f"report: {a.out}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
