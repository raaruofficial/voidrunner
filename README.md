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
- **.skr identity** — sign-in via Mobile Wallet Adapter 2.0; one identity
  across the arcade.
- **Arcade pricing, in play units** — 25¢ per play · 14 plays for $3.50 ·
  30-day pass for $7. Voluntary SKR support ladder for pilots who want to
  feed the funnel.

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

## Status

Built for the Solana Mobile CLOCK IN hackathon (October 2026) as a
functional demo build with simulated funds. The road from here: live game
endpoint cutover, then dApp Store publication.

Solo builder — raaru.skr · X / Twitter:
[@raaruofficial](https://x.com/raaruofficial)
