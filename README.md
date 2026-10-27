# VOIDRUNNER

**Don't dodge the lightning. Steal it.**

A bullet-hell survival game for the Solana Seeker. In VOIDRUNNER the
lightning *buffs* you: fly into the storm, harvest the charge, and turn it
back on the fleet.

- **100-wave campaign** — a named boss every 5 waves across ten boss
  families, telegraphed charges, constant repositioning — plus a seeded
  endless mode.
- **Signature weapons, not variants** — Starlance, Quasar, Halcyon and
  more, each with its own slot, role, and mastery crown.
- **Excalibur sorties** — when a boss pushes you past the edge, your swords
  wake themselves: four sorties, each carving a slice of the boss's max HP,
  hard-capped so skill still decides the fight.
- **Procedural dark-synthwave score** — generated in-engine (WebAudio, no
  audio files), with music mixed as the star and effects ducking under it.
- **.skr identity** — sign in by typing your .skr handle; one identity
  across the arcade. The MWA 2.0 layer in this shell is for on-device
  wallet signing, not sign-in.
- **Arcade pricing, in play units** — 25¢ per play · 14 plays for $3.50 ·
  30-day pass for $7. Voluntary SKR support ladder for pilots who want to
  feed the funnel — simulated in this build, like all funds in it.

## This repo

Native Android shell (Kotlin + Jetpack Compose) around the game:

- `app/src/main/java/com/voidrunner/app/wallet/` — the MWA 2.0 wallet
  layer: connect, signMessage, and sign-and-send, plus the
  `window.VoidrunnerWallet` JS bridge that meets the game in the WebView.
- `app/src/main/java/com/voidrunner/app/game/GameConfig.kt` — how game
  content reaches the APK. The game itself is a server-backed build
  (profiles, economy, leaderboards) that runs on its live service; this
  shell ships the game's front page as a bundled asset, and the production
  endpoint wiring is a single constant away.
- `.github/workflows/android.yml` — CI builds the debug APK on every push
  and uploads it as the `voidrunner-debug-apk` artifact.

## Build

CI provisions its own Gradle; locally the same command works with any
recent Gradle:

```
gradle :app:assembleDebug
```

The APK lands in `app/build/outputs/apk/debug/`.

## Signed release

The current signed build is **[v1.0.2](https://github.com/raaruofficial/voidrunner/releases/tag/v1.0.2)** —
the release APK (declared versionName `1.0.2`, versionCode 2) signed with
the publisher keystore (certificate CN=raaru.skr, SHA-256 `30:7F:68:39…81:11`),
package `com.voidrunner.app`. Assets in the earlier v1.0.1 release declare
versionName 0.1.0-hackathon (versionCode 1); v1.0.1 is the git tag of the
build commit `d577fd0`. The v1.0.1 release page also carries the CLOCK IN
filing's demo video and pitch deck of record.

## Status

Built for the Solana Mobile CLOCK IN hackathon (October 2026) as a
functional demo build with simulated funds. The road from here: live game
endpoint cutover, then dApp Store publication.

Solo builder — raaru.skr · X / Twitter:
[@raaruofficial](https://x.com/raaruofficial)
