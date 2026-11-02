# VOIDRUNNER R-1 on Firebase Test Lab — construction pieces

The FTL route for the v1.0.13 gate cell (owner: "Set up Google
testing", 2026-11-01). FTL devices sit on public DNS, so the CI
rig's shape (candidate bytes spoofed at the production hostname)
cannot exist there. The FTL shape instead:

- **Public staging origin** — `https://voidrunner-staging.137-184-143-128.sslip.io`
  (ore-spare + Caddy, the estate's sslip pattern; no new recurring
  cost). `staging-origin.ts` (this folder) is its front: sealed cure
  client statics + `/actions` proxied to the composition's staging
  server (`tools/gate-staging/` — production server bundle +
  ANS-seam epilogue, fixture `gatefixture113.skr` → the Mock key).
- **Staging shell** — the sealed v1.0.13 commit (`1dd18d4`) with
  EXACTLY ONE constant changed: `GameConfig.GAME_URL` points at the
  staging origin. Built on branch `ftl/r1-gate-prep`. A TEST
  INSTRUMENT, never a submission candidate: the submission binary
  remains the sealed APK `56133172…84a8`.
- **Test APK** — `tools/ftl-gate-test/`: the gate choreography
  ported into an AndroidX/UIAutomator instrumentation test (FTL's
  driver must live in a test APK; this also removes the CI rig's
  outside uiautomator dump channel — the component that kept
  failing — by construction).
- **Mock MWA Wallet** — rides FTL's `--additional-apks` (pinned
  `d444aff0`, the documented fixed-key configuration).

Full record: `FTL_CONSTRUCTION.md` in the go-live-patch folder's
`ftl/` directory (construction, census, local validation, first-run
confirmation list) + `OWNER_TAP_PACKAGE.md` (the owner's two taps).
Validation workflow: `.github/workflows/ftl-gate-validate.yml`.
