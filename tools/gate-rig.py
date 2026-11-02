#!/usr/bin/env python3
"""VOIDRUNNER gate serving rig (CURE_PLAN §2, R-1/R-2).

Serves a candidate bundle's static bytes at the PRODUCTION hostname
on the CI runner, so the sealed shell — whose GAME_URL is compiled
to the production origin — loads the candidate client, while every
non-static request (POST /actions, the bind/proof protocol) is
proxied to the real production origin: server read-back in the gate
cell is genuine production state, never a stub.

The runner presents a leaf certificate for the production hostname
signed by a run-local CA; the gate-suite action installs that CA
into the emulator's system trust store and bind-mounts a hosts file
pointing the hostname at the runner (10.0.2.2). Every request is
logged (path + served-from) so the evidence shows which bytes the
device actually received.

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
import urllib.parse

STATIC_PREFIXES = ("/assets/",)
STATIC_EXACT = ("/", "/index.html")


class RigHandler(http.server.BaseHTTPRequestHandler):
    serve_dir: pathlib.Path = pathlib.Path(".")
    upstream_host: str = ""
    upstream_port: int = 443

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
        print(f"RIG static {path} -> {target.name} ({len(data)}B)", flush=True)
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
        print(f"RIG proxy {self.command} {path} -> upstream", flush=True)
        conn = http.client.HTTPSConnection(self.upstream_host, self.upstream_port, timeout=30)
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
            print(f"RIG proxy ERROR {self.command} {path}: {e}", flush=True)
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
    RigHandler.upstream_host = upstream.hostname
    RigHandler.upstream_port = upstream.port or 443

    server = http.server.ThreadingHTTPServer(("0.0.0.0", args.port), RigHandler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(args.cert, args.key)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    print(f"RIG listening :{args.port} serve={args.serve} upstream={args.upstream}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
