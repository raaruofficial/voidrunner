#!/usr/bin/env python3
"""VOIDRUNNER gate DNS responder (SEAL_V113 ADDENDUM #2, execution 2).

Why this exists: the gate wrapper's /system/etc/hosts bind-mount
never took effect for the device resolver — in every gate execution
the wrapper's own diagnostic printed 'ping: unknown host' and the
device resolved the production hostname through public DNS instead,
loading the LIVE production bytes while the read-backs asserted
against the staging server (execution 41403201148: rig log shows
zero device hits; the gate screen that rendered was production's).
netd/mainline-resolver reads the hosts file at its own start, long
before any wrapper mount, and does not re-read it.

The emulator's supported redirection point is its DNS: launched
with '-dns-server 10.0.2.2', the guest asks the host (10.0.2.2 is
the guest-side alias of the host loopback in the emulator's NAT)
for every lookup. This responder answers the production hostname
with 10.0.2.2 — where the serving rig listens — and forwards every
other query verbatim to the runner's upstream resolver, relaying
the response untouched. UDP/53, stdlib only.

Usage: gate-dns.py --name voidrunner-2hm7p.ondigitalocean.app
                   [--addr 10.0.2.2] [--bind 127.0.0.1]
"""
import argparse
import socket
import struct
import sys

QTYPE_A = 1
QTYPE_AAAA = 28


def parse_question(packet):
    """Return (name, qtype, question_end_offset) or None."""
    if len(packet) < 12:
        return None
    qdcount = struct.unpack(">H", packet[4:6])[0]
    if qdcount < 1:
        return None
    off = 12
    labels = []
    while off < len(packet):
        ln = packet[off]
        if ln == 0:
            off += 1
            break
        if ln & 0xC0:
            return None  # compression in a query question: not expected
        labels.append(packet[off + 1:off + 1 + ln].decode("ascii", "replace"))
        off += 1 + ln
    if off + 4 > len(packet):
        return None
    qtype, _qclass = struct.unpack(">HH", packet[off:off + 4])
    return ".".join(labels).lower(), qtype, off + 4


def build_a_response(query, qend, addr):
    tid, flags, qd, _an, _ns, _ar = struct.unpack(">HHHHHH", query[:12])
    question = query[12:qend]
    # Response flags: QR + RD copied + RA, RCODE=0. Answer: name pointer
    # to the question, type A, class IN, TTL 60, rdlength 4.
    hdr = struct.pack(">HHHHHH", tid, flags | 0x8000 | 0x0080, qd, 1, 0, 0)
    ans = struct.pack(">HHHIH", 0xC00C, QTYPE_A, 1, 60, 4) + socket.inet_aton(addr)
    return hdr + question + ans


def build_nodata_response(query, qend):
    tid, flags, qd, _an, _ns, _ar = struct.unpack(">HHHHHH", query[:12])
    question = query[12:qend]
    hdr = struct.pack(">HHHHHH", tid, flags | 0x8000 | 0x0080, qd, 0, 0, 0)
    return hdr + question


def upstream_resolver():
    try:
        for line in open("/etc/resolv.conf"):
            parts = line.split()
            if len(parts) == 2 and parts[0] == "nameserver":
                return parts[1]
    except OSError:
        pass
    return "127.0.0.53"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--addr", default="10.0.2.2")
    ap.add_argument("--bind", default="127.0.0.1")
    args = ap.parse_args()
    name = args.name.lower()
    upstream = upstream_resolver()

    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.bind, 53))
    fwd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    fwd.settimeout(3)
    print(f"GATE-DNS listening {args.bind}:53 name={name} -> {args.addr}, "
          f"upstream={upstream}", flush=True)

    while True:
        try:
            data, peer = srv.recvfrom(4096)
        except OSError:
            continue
        parsed = parse_question(data)
        if parsed and parsed[0] == name and parsed[1] in (QTYPE_A, QTYPE_AAAA):
            qtype, qend = parsed[1], parsed[2]
            if qtype == QTYPE_A:
                resp = build_a_response(data, qend, args.addr)
                print(f"GATE-DNS answer {name} A -> {args.addr} (for {peer[0]})", flush=True)
            else:
                resp = build_nodata_response(data, qend)
                print(f"GATE-DNS answer {name} AAAA -> NODATA (for {peer[0]})", flush=True)
            srv.sendto(resp, peer)
            continue
        # Everything else: forward verbatim, relay verbatim.
        try:
            fwd.sendto(data, (upstream, 53))
            resp, _ = fwd.recvfrom(4096)
            srv.sendto(resp, peer)
        except OSError as e:
            print(f"GATE-DNS forward failed for {peer[0]}: {e}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
