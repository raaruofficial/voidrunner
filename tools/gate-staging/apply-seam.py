#!/usr/bin/env python3
"""Build the GATE STAGING server module from the production server bundle.

Owner ruling 2026-11-01 ("follow their docs completely"): no .skr
fixture can exist for a test wallet (Solana Mobile docs: a .skr is
only minted once per device), so R-1 closes BY COMPOSITION — the
identical production server build, with ONE seam stubbed: the ANS
handle-ownership read for ONE fixture handle.

The production bundle already carries the designed seam: module-scope
`var skrResolverFixture = null`, consulted first by
resolveSkrOwnerDetail (source: server/src/binding.ts exports
installSkrOwnerResolverFixture, "Production never installs one").
The bundle exports no setter, so this script produces the staging
module as:

    staging bytes = production bytes + EPILOGUE

where the EPILOGUE (appended, same module scope) assigns the fixture
ONLY when the staging process carries BOTH config env vars
(VR_GATE_FIXTURE_HANDLE / VR_GATE_FIXTURE_OWNER). For the fixture
handle, the registry read returns the configured owner as
registered; EVERY other handle delegates to the bundle's own live
registry query (querySkrOwner) — byte-identical production logic.

Properties enforced here (the script refuses otherwise):
  * input sha256 == the production bundle of record
    (f487b4fdfc…9700, cure-bundle/BUNDLE_RECORD.md);
  * output is a strict byte-extension of the input
    (output.startswith(input)) — the delta is the epilogue alone;
  * both hashes are printed for the seal record.

The input bundle is distributed as a GitHub RELEASE ASSET
(tag gate-staging-fixtures-v1), never as a git blob: it carries
server-only config, and push protection refuses it in history.

The staging module NEVER ships to production; production keeps
running the unmodified bundle with the seam null.
"""
import hashlib
import pathlib
import sys

EXPECTED_SHA256 = "f487b4fdfc18985d79b108bd10b0edc7677922e1d72212e714c6bd8090019700"

EPILOGUE = """
// ── GATE STAGING SEAM (test-only; this module copy never ships) ─────
// Engages the bundle's own designed resolver-fixture seam
// (skrResolverFixture, declared above; production leaves it null).
// Config-gated: active only when BOTH env vars are present in the
// staging process. For the fixture handle the ANS ownership read
// returns the configured owner as registered; every other handle
// delegates to the bundle's own live registry query. Appended by
// tools/gate-staging/apply-seam.py; the staging module is the
// production bundle byte-for-byte plus this block, nothing else.
if (process.env.VR_GATE_FIXTURE_HANDLE && process.env.VR_GATE_FIXTURE_OWNER) {
  const gateFixtureHandle = String(process.env.VR_GATE_FIXTURE_HANDLE).toLowerCase();
  const gateFixtureOwner = String(process.env.VR_GATE_FIXTURE_OWNER);
  skrResolverFixture = async (normalized) => {
    if (normalized === gateFixtureHandle)
      return { status: "registered", ownerPubkey: gateFixtureOwner };
    return querySkrOwner(normalized, SKR_RESOLUTION_TIMEOUT_MS);
  };
}
"""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    here = pathlib.Path(__file__).resolve().parent
    src = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else here / "server-actions.production.js"
    dst = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else here / "server-actions.staging.js"
    raw = src.read_bytes()
    digest = sha256(raw)
    if digest != EXPECTED_SHA256:
        print(f"REFUSED: input sha256 {digest} != production bundle of record {EXPECTED_SHA256}")
        return 1
    out = raw + EPILOGUE.encode()
    assert out.startswith(raw), "staging module must be a strict byte-extension of production"
    dst.write_bytes(out)
    print(f"production module: {src.name} sha256={digest} bytes={len(raw)}")
    print(f"staging module:    {dst.name} sha256={sha256(out)} bytes={len(out)} (delta=+{len(out) - len(raw)}B epilogue only)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
