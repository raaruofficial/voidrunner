# VOIDRUNNER — Android app

**VOIDRUNNER** is a pay-per-play bullet-hell arcade game for the Solana Seeker phone.
25¢ per play. `.skr` identity. Non-custodial: player funds live in the Seeker's
Seed Vault; the game never holds private keys.

This repo is the **native Android app** built for the
**CLOCK IN hackathon** (Solana Mobile / RadiantsDAO) — submissions close
**October 8, 2026, 23:59 PT**. The hackathon requires a real Android APK with
Mobile Wallet Adapter + Solana Mobile Stack integration; web wrappers score
poorly. So this is a genuine native app (Kotlin + Jetpack Compose): native
splash, menu, wallet, and settings screens, with the game rendering inside a
WebView on the game screen only — and a `VoidrunnerWallet` JS bridge as the
seam where the native MWA wallet meets the game.

> Status: **Step 1 of the hackathon push** — project scaffold, native screens,
> MWA connect/session/sign scaffolding, JS bridge, CI. Step 2 (game wiring,
> `signTransaction`, demo video, deck) comes next.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  MainActivity (Compose Navigation)              │
│  splash → home → game / wallet / settings       │
├─────────────────────────────────────────────────┤
│  WalletScreen ──► WalletManager ──► MWA 2.0     │  native, no web
│                      │            (Seed Vault)   │
│                      ▼                           │
│  GameScreen: WebView + VoidrunnerWallet bridge  │  game content only
│     window.VoidrunnerWallet.{                   │
│       connectWallet, signMessage,                │
│       signTransaction, getPublicKey }            │
└─────────────────────────────────────────────────┘
```

- **Native layer** (`app/src/main/java/com/voidrunner/app/`): lifecycle-correct
  single activity, Compose Navigation, MWA session management, JS bridge.
- **Game content**: loaded by the WebView per `GameConfig` — see the open
  decision below. **The game's source is NOT in this repo.**
- **Wallet**: official `com.solanamobile:mobile-wallet-adapter-clientlib-ktx:2.0.8`.
  Connect → association intent → Seed Vault approval → session. Signing happens
  in the wallet; the app only ever sees public keys and signatures.

### JS bridge contract (`window.VoidrunnerWallet`)

| Method | Args | Result |
|---|---|---|
| `getVersion()` | — | `"1"` (sync) |
| `isConnected()` | — | `true`/`false` (sync) |
| `getPublicKey()` | — | Base58 address or `""` (sync) |
| `connectWallet(requestId)` | request id | ack sync; async → `__voidrunnerWalletResolve(id, json)` |
| `signMessage(requestId, message)` | request id, text | async → `{ ok, data: { signature } }` |
| `signTransaction(requestId, txBase64)` | request id, tx | **stub** — lands in step 2 |

Async results arrive as `window.__voidrunnerWalletResolve(requestId, resultJson)`
where `resultJson` is `{ ok: true, data: {...} }` or `{ ok: false, error: "..." }`.

## Build

### From `git clone` to APK (no Android Studio needed)

CI builds a debug APK on every push to `main` — download it from the
workflow's **Artifacts** (`voidrunner-debug-apk`).

### Local build (Android Studio)

1. Open this directory in Android Studio (it syncs Gradle automatically).
2. Run ▶ on a device or emulator (API 28+; Seeker runs Android 15).
3. Or from a terminal with Gradle installed: `gradle :app:assembleDebug`
   → `app/build/outputs/apk/debug/app-debug.apk`.

Requirements: JDK 17, Android SDK with API 35, Gradle 8.11.1 (CI provisions it).

## Release signing (no secrets in this repo — ever)

Release APKs are signed from GitHub Secrets. Set these in
**Settings → Secrets and variables → Actions**:

| Secret | Contents |
|---|---|
| `KEYSTORE_BASE64` | `base64` of the `.jks` release keystore |
| `KEYSTORE_PASSWORD` | keystore password |
| `KEY_ALIAS` | key alias |
| `KEY_PASSWORD` | key password |

Then tag a release: `git tag v0.1.0 && git push origin v0.1.0` — the
`build-release` job produces the signed APK as `voidrunner-release-apk`.

> ⚠️ **Guard the keystore like the publisher wallet.** Losing it means you can
> never ship updates to the same app listing again. The backup password lives
> with the developer, never in this repo.

## OPEN QUESTIONS — morning decisions

### 1. How does the game content get into the APK? ⭐ key decision
- **(a) Hosted URL** — WebView loads the public game URL (`GameConfig.GAME_URL`).
  Simplest, but needs the game publicly reachable and is the weakest story
  against the hackathon's "no web wrappers" rule.
- **(b) Bundled asset** — a static export of the game ships under
  `app/src/main/assets/game/`, loaded as `file:///android_asset/game/index.html`.
  Best offline behavior; needs a static build of the game.
- **(c) Hybrid (recommended)** — bundled game (b) + the `VoidrunnerWallet` JS
  bridge to the native MWA wallet. Native wallet, native menus, native
  navigation — the game is content, the app is an app.

The game itself is currently a hosted web artifact and **its source is not in
this repo** — do not attempt to copy game code until this decision is made.

### 2. MWA on-device verification
The connect/session/sign flow is scaffolded against the official MWA 2.0 API,
but it has never run against a real Seeker wallet. First device test must
cover: connect approval → public key displayed → sign test message →
disconnect. The `signTransaction` path is stubbed until step 2.

### 3. Release keystore
Generate once (`keytool -genkeypair`), back up the password offline, upload to
GitHub Secrets per the table above. Required before the dApp Store submission.

### 4. dApp Store submission (after the hackathon)
Signed release APK, Publisher Portal KYC, ~0.2 SOL publisher wallet, mainnet
build. Separate checklist — not part of this sprint.

## Roadmap

- [x] **Step 1** — scaffold: native app, MWA connect/sign, JS bridge, CI (this repo)
- [ ] **Step 2** — game wiring: `signTransaction` via MWA 2.0 `signAndSendTransactions`,
      game-side bridge integration, auth-token persistence
- [ ] **Step 3** — hackathon materials: ~3-min demo video (on device), pitch deck,
      Align platform submission
- [ ] **Step 4** — dApp Store: release keystore, KYC, listing, publish

## Links

- CLOCK IN hackathon: https://solanamobile.radiant.nexus/
- MWA docs: https://github.com/solana-mobile/solana-mobile-docs (`android-native/`)
- MWA 2.0 spec: https://solana-mobile.github.io/mobile-wallet-adapter/spec/spec.html
- Seeker Publishing Portal: https://publish.solanamobile.com
