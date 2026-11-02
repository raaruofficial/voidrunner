// GATE STAGING server (VOIDRUNNER v1.0.13 cure, R-1/R-2 composition).
//
// An HTTP front for the production server bundle (byte-identical plus
// the apply-seam.py epilogue) speaking the exact wire shape the game
// client and the gate driver's read-backs use against production:
//
//   POST /actions  {action, args, actionCallId}
//     -> 200 {data: <handler result>}
//     -> 200 {error: {code, message}}   on a thrown action error
//   GET  /health   -> {ok, fixture}
//
// In-process invocation mirrors the lane's own regression harness
// contract (scripts/bind-regression.ts): Actions[name].handler(ctx,
// args). The action layer, challenge issuance, verifyBindSignature,
// the bind state machine and session issuance are the production
// bundle's own — nothing is re-implemented here.
//
// The data plane is the production bundle's own (its configured
// store): every write the gate flow makes is confined to the ONE
// fixture handle named by VR_GATE_FIXTURE_HANDLE, and the gate-suite
// janitor step sweeps that handle's rows after the run and verifies
// zero residue. Reads for every other handle behave exactly as
// production (the seam delegates non-fixture registry reads to the
// bundle's own live ANS query).
//
// Refuses to start without the fixture config — an ungated staging
// copy of the production module must never run.
const modulePath = process.env.VR_GATE_SERVER_MODULE;
const fixtureHandle = (process.env.VR_GATE_FIXTURE_HANDLE ?? "").toLowerCase();
const fixtureOwner = process.env.VR_GATE_FIXTURE_OWNER ?? "";
const port = Number(process.env.VR_GATE_STAGING_PORT ?? "8791");

if (!modulePath) throw new Error("VR_GATE_SERVER_MODULE is required");
if (!fixtureHandle || !fixtureOwner) {
  throw new Error("VR_GATE_FIXTURE_HANDLE and VR_GATE_FIXTURE_OWNER are required (config-gated seam)");
}

const { Actions } = await import(modulePath);
if (!Actions || typeof Actions !== "object") throw new Error("staging module did not export Actions");

const CODE_TOKEN = /^([A-Z][A-Z0-9_]{2,})(?::|\s)/;
function errorShape(err: unknown): { code: string; message: string } {
  const message = err instanceof Error ? err.message : String(err);
  const m = CODE_TOKEN.exec(message);
  return { code: m ? m[1] : "ACTION_ERROR", message };
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port,
  async fetch(req) {
    const url = new URL(req.url);
    if (req.method === "GET" && url.pathname === "/health") {
      return Response.json({ ok: true, fixture: fixtureHandle });
    }
    if (req.method === "POST" && url.pathname === "/actions") {
      const started = Date.now();
      let action = "?";
      try {
        const body = (await req.json()) as { action?: string; args?: Record<string, unknown> };
        action = String(body?.action ?? "");
        const entry = (Actions as Record<string, { handler?: unknown }>)[action];
        if (!entry || typeof entry.handler !== "function") {
          console.log(`staging action=${action} outcome=error code=UNKNOWN_ACTION ms=${Date.now() - started}`);
          return Response.json({ error: { code: "UNKNOWN_ACTION", message: `Unknown action: ${action}` } });
        }
        const data = await (entry.handler as (ctx: unknown, args: unknown) => Promise<unknown>)({}, body?.args ?? {});
        console.log(`staging action=${action} outcome=ok ms=${Date.now() - started}`);
        return Response.json({ data: data ?? null });
      } catch (err) {
        const shape = errorShape(err);
        console.log(`staging action=${action} outcome=error code=${shape.code} ms=${Date.now() - started}`);
        return Response.json({ error: shape });
      }
    }
    return new Response("not found", { status: 404 });
  },
});

console.log(`gate staging server on http://127.0.0.1:${server.port} fixture=${fixtureHandle} owner=${fixtureOwner}`);
