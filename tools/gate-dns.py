#!/usr/bin/env python3
"""VOIDRUNNER gate DNS responder (SEAL_V113 ADDENDUM #2, execution 2;
bind + server-list cure ADDENDUM #3).

Why this exists: the gate wrapper's /system/etc/hosts bind-mount
never took effect for the device resolver — in every gate execution
the wrapper's own diagnostic printed 'ping: unknown host' and the
device resolved the production hostname through public DNS instead,
loading the LIVE production bytes while the read-backs asserted
against the staging server (execution 41403201148: rig log shows
zero device hits; the gate screen that rendered was production's).
netd/mainline-resolver reads the hosts file at its own start, long
before any wrapper mount, and does not re-read it.

Execution 2 (41405906380) moved redirection to the emulator's DNS
('-dns-server 10.0.2.2', this responder bound to 127.0.0.1) and the
device query STILL never arrived: the responder logged exactly one
answer (the runner-side self-check, sent directly to 127.0.0.1:53)
while the WebView rendered net::ERR_NAME_NOT_RESOLVED. Two delivery
models fit that evidence — (a) '-dns-server' names the emulator DNS
proxy's upstreams IN THE HOST NAMESPACE, where '10.0.2.2' is not a
host address at all (it is the guest-side alias of the host
loopback) and the forwarded query is routed out and dropped; or
(b) the guest resolver is handed 10.0.2.2 and slirp delivers its
UDP/53 to a NON-loopback host interface, where a 127.0.0.1-only
bind cannot hear it. The ADDENDUM #3 configuration satisfies both
with one shape: the emulator is launched with
'-dns-server 127.0.0.1,10.0.2.2' (under (a) the proxy's first
upstream is the runner's own loopback; under (b) netd fails over
from its own loopback to 10.0.2.2) and this responder binds
0.0.0.0, hearing every host interface. The ANSWER stays 10.0.2.2:
that is the address the GUEST connects to, and slirp maps it to
the host loopback where the serving rig listens (0.0.0.0:443).
Every other query is forwarded verbatim to the runner's upstream
resolver and the response relayed untouched. UDP/53, stdlib only.

Every query and answer is logged with a timestamp and the local
(destination) address it arrived on, so the run's evidence shows
whether — and via which host interface — a device query ever
reached the responder, distinct from the pre-boot self-check.

Usage: gate-dns.py --name voidrunner-2hm7p.ondigitalocean.app
                   [--addr 10.0.2.2] [--bind 0.0.0.0]
"""
import argparse
import socket
import struct
import sys
import time

QTYPE_A = 1
QTYPE_AAAA = 28


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


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
    ap.add_argument("--bind", default="0.0.0.0")
    args = ap.parse_args()
    name = args.name.lower()
    upstream = upstream_resolver()

    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # IP_PKTINFO: record the local (destination) address of every
    # query — the evidence of WHICH host interface carried it.
    srv.setsockopt(socket.IPPROTO_IP, socket.IP_PKTINFO, 1)
    srv.bind((args.bind, 53))
    fwd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    fwd.settimeout(3)
    log(f"GATE-DNS listening {args.bind}:53 name={name} -> {args.addr}, "
        f"upstream={upstream}")

    while True:
        try:
            data, ancdata, _flags, peer = srv.recvmsg(4096, 64)
        except OSError:
            continue
        dst = "?"
        for level, ctype, cdata in ancdata:
            if level == socket.IPPROTO_IP and ctype == socket.IP_PKTINFO \
                    and len(cdata) >= 12:
                dst = socket.inet_ntoa(cdata[8:12])
        parsed = parse_question(data)
        if parsed:
            log(f"GATE-DNS query {parsed[0]} type={parsed[1]} "
                f"src={peer[0]} dst={dst}")
        if parsed and parsed[0] == name and parsed[1] in (QTYPE_A, QTYPE_AAAA):
            qtype, qend = parsed[1], parsed[2]
            if qtype == QTYPE_A:
                resp = build_a_response(data, qend, args.addr)
                log(f"GATE-DNS answer {name} A -> {args.addr} (for {peer[0]})")
            else:
                resp = build_nodata_response(data, qend)
                log(f"GATE-DNS answer {name} AAAA -> NODATA (for {peer[0]})")
            srv.sendto(resp, peer)
            continue
        # Everything else: forward verbatim, relay verbatim.
        try:
            fwd.sendto(data, (upstream, 53))
            resp, _ = fwd.recvfrom(4096)
            srv.sendto(resp, peer)
        except OSError as e:
            log(f"GATE-DNS forward failed for {peer[0]}: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
