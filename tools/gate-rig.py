#!/usr/bin/env python3
"""VOIDRUNNER gate serving rig (CURE_PLAN §2, R-1/R-2).

Serves a candidate bundle's static bytes at the PRODUCTION hostname
on the CI runner, so the sealed shell — whose GAME_URL is compiled
to the production origin — loads the candidate client, while every
non-static request (POST /actions, the bind/proof protocol) is
proxied to the upstream origin.

Upstream modes: production (https://voidrunner-2hm7p.ondigitalocean.app
— the original R-1/R-2 design) or the GATE STAGING composition
(http://127.0.0.1:8791 — the production server bundle running on the
runner with the ANS registry seam stubbed for one fixture handle;
owner ruling 2026-11-01, R-1 closes by composition). The mode is
selected by the gate-suite action's server-mode input; the rig only
forwards, it never stubs.

The runner presents a leaf certificate for the production hostname
signed by a run-local CA; the gate-suite action installs that CA
into the emulator's system trust store, and the production hostname
is redirected to the runner at the emulator's DNS (tools/gate-dns.py
answers it with 10.0.2.2, the guest-side alias of the host). Every
request is logged (path + served-from) so the evidence shows which
bytes the device actually received.

Usage:
  gate-rig.py --cert leaf.pem --key leaf.key --serve <public-dir>
              --upstream https://voidrunner-2hm7p.ondigitalocean.app
              [--port 443]
Stdlib only.
"""
import argparse
import http.client
import http.server
import mimetypes
import pathlib
import ssl
import sys
import time
import urllib.parse

STATIC_PREFIXES = ("/assets/",)
STATIC_EXACT = ("/", "/index.html")


def ts():
    return time.strftime("%H:%M:%S")


class RigServer(http.server.ThreadingHTTPServer):
    """ThreadingHTTPServer that wraps TLS per accepted connection and
    LOGS every connection + handshake outcome (ADDENDUM #3 exec 2).

    Why: with the listening socket pre-wrapped, a client that aborts
    the handshake (e.g. it does not trust the rig CA) fails inside
    socketserver's get_request — and socketserver silently swallows
    the resulting SSLError (an OSError) with no log line anywhere.
    Run 41410132746 proved the device resolved the production
    hostname to this rig (10.0.2.2) yet recorded zero requests and
    zero errors; the fetch leg was invisible. Here an aborted
    handshake prints 'RIG tls-FAIL' and a completed one 'RIG conn',
    so the run's evidence states which leg carried — or refused —
    the device's fetch."""

    daemon_threads = True
    tls_ctx: ssl.SSLContext = None

    def get_request(self):
        raw, addr = self.socket.accept()
        peer = f"{addr[0]}:{addr[1]}"
        try:
            conn = self.tls_ctx.wrap_socket(raw, server_side=True)
        except (ssl.SSLError, OSError) as e:
            print(f"[{ts()}] RIG tls-FAIL {peer}: {type(e).__name__}: {e}",
                  flush=True)
            raw.close()
            raise
        print(f"[{ts()}] RIG conn {peer} tls-ok", flush=True)
        return conn, addr


class RigHandler(http.server.BaseHTTPRequestHandler):
    serve_dir: pathlib.Path = pathlib.Path(".")
    upstream_host: str = ""
    upstream_port: int = 443
    upstream_scheme: str = "https"

    def log_message(self, fmt, *args):  # noqa: A003 — keep stderr clean; we log explicitly
        pass

    def _serve_static(self, path: str):
        rel = "index.html" if path in ("/", "") else path.lstrip("/")
        target = (self.serve_dir / rel).resolve()
        if not str(target).startswith(str(self.serve_dir.resolve())) or not target.is_file():
            self._proxy(path)
            return
        data = target.read_bytes()
        ctype = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        print(f"[{ts()}] RIG static {path} -> {target.name} ({len(data)}B)", flush=True)
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _proxy(self, path: str):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in ("host", "content-length", "connection")}
        headers["Host"] = self.upstream_host
        if body is not None:
            headers["Content-Length"] = str(len(body))
        print(f"[{ts()}] RIG proxy {self.command} {path} -> upstream", flush=True)
        conn_cls = http.client.HTTPSConnection if self.upstream_scheme == "https" else http.client.HTTPConnection
        conn = conn_cls(self.upstream_host, self.upstream_port, timeout=30)
        try:
            conn.request(self.command, path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
        except Exception as e:  # upstream failure must be loud, not silent
            print(f"[{ts()}] RIG proxy ERROR {self.command} {path}: {e}", flush=True)
            payload = f"gate rig upstream error: {e}".encode()
            self.send_response(502)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        finally:
            conn.close()

    def _route(self):
        path = urllib.parse.urlsplit(self.path).path
        if path in STATIC_EXACT or any(path.startswith(p) for p in STATIC_PREFIXES):
            self._serve_static(path)
        else:
            self._proxy(self.path)

    do_GET = _route
    do_POST = _route
    do_HEAD = _route
    do_PUT = _route
    do_DELETE = _route


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--serve", required=True)
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--port", type=int, default=443)
    args = ap.parse_args()

    upstream = urllib.parse.urlsplit(args.upstream)
    RigHandler.serve_dir = pathlib.Path(args.serve)
    RigHandler.upstream_scheme = upstream.scheme or "https"
    RigHandler.upstream_host = upstream.hostname
    RigHandler.upstream_port = upstream.port or (443 if RigHandler.upstream_scheme == "https" else 80)

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(args.cert, args.key)
    RigServer.tls_ctx = ctx
    server = RigServer(("0.0.0.0", args.port), RigHandler)
    print(f"[{ts()}] RIG listening :{args.port} serve={args.serve} upstream={args.upstream}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
