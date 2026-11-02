// VOIDRUNNER gate — PUBLIC STAGING ORIGIN front (FTL construction).
//
// The one HTTP front of the R-1 staging composition when it lives at
// a public origin (Firebase Test Lab devices sit on public DNS and
// cannot be redirected to a runner-local rig the way the CI emulator
// is). Routing mirrors tools/gate-rig.py exactly:
//
//   GET /, /index.html, /assets/*   -> the sealed cure client statics
//                                      (tools/gate-fixtures/cure-public,
//                                      JS asset 03bdb43e…2843)
//   everything else (POST /actions, GET /health, ...)
//                                   -> proxied to the staging server
//                                      (tools/gate-staging/staging-server.ts:
//                                      the production server bundle +
//                                      the ANS-seam epilogue)
//
// One program, two postures, selected by env:
//   ore-spare (the standing origin): plain HTTP on VR_ORIGIN_PORT
//     (default 8793) bound to 127.0.0.1; Caddy terminates public TLS
//     for voidrunner-staging.137-184-143-128.sslip.io and proxies in.
//   CI validation: VR_ORIGIN_CERT/KEY set -> serves TLS directly on
//     port 443 with the run-local CA leaf for the staging hostname,
//     exactly the wire shape FTL will see (real public name, real
//     TLS, real DNS answer — only the answer's address differs).
//
// Refuses to start without a static dir — serving the wrong client
// bytes silently is the failure this whole construction exists to
// prevent. Every request is logged (path + served-from), the same
// evidence idiom as the gate rig: the log proves which bytes the
// device actually received.
const staticDir = process.env.VR_ORIGIN_STATIC_DIR;
const upstream = process.env.VR_ORIGIN_UPSTREAM ?? "http://127.0.0.1:8791";
const port = Number(process.env.VR_ORIGIN_PORT ?? "8793");
const certFile = process.env.VR_ORIGIN_CERT;
const keyFile = process.env.VR_ORIGIN_KEY;

if (!staticDir) throw new Error("VR_ORIGIN_STATIC_DIR is required (the sealed cure client statics)");

const STATIC_PREFIXES = ["/assets/"];
const STATIC_EXACT = new Set(["/", "/index.html"]);

async function serveStatic(pathname: string): Promise<Response | null> {
  const rel = pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "");
  const file = Bun.file(`${staticDir}/${rel}`);
  if (!(await file.exists())) return null;
  console.log(`ORIGIN static ${pathname} -> ${rel} (${file.size}B)`);
  return new Response(file);
}

async function proxy(req: Request, url: URL): Promise<Response> {
  const target = upstream + url.pathname + url.search;
  console.log(`ORIGIN proxy ${req.method} ${url.pathname} -> upstream`);
  const headers = new Headers(req.headers);
  headers.delete("host");
  headers.delete("connection");
  const init: RequestInit = { method: req.method, headers, redirect: "manual" };
  if (req.method !== "GET" && req.method !== "HEAD") {
    init.body = await req.arrayBuffer();
  }
  try {
    const resp = await fetch(target, init);
    const body = await resp.arrayBuffer();
    const outHeaders = new Headers(resp.headers);
    outHeaders.delete("transfer-encoding");
    outHeaders.delete("connection");
    outHeaders.delete("content-length");
    return new Response(body, { status: resp.status, headers: outHeaders });
  } catch (err) {
    console.log(`ORIGIN proxy ERROR ${req.method} ${url.pathname}: ${err}`);
    return new Response(`staging origin upstream error: ${err}`, { status: 502 });
  }
}

const tls = certFile && keyFile ? { cert: Bun.file(certFile), key: Bun.file(keyFile) } : undefined;

const server = Bun.serve({
  hostname: tls ? "0.0.0.0" : "127.0.0.1",
  port,
  tls,
  async fetch(req) {
    const url = new URL(req.url);
    if (STATIC_EXACT.has(url.pathname) || STATIC_PREFIXES.some((p) => url.pathname.startsWith(p))) {
      const hit = await serveStatic(url.pathname);
      if (hit) return hit;
    }
    return proxy(req, url);
  },
});

console.log(`gate staging origin on http${tls ? "s" : ""}://${server.hostname}:${server.port} static=${staticDir} upstream=${upstream}`);
