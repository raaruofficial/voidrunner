package com.voidrunner.app.game

/**
 * How the game content reaches the APK.
 *
 * HISTORY — Option B wiring (2026-10-12), honest scope:
 * The WebView loaded the bundled front page at
 * `file:///android_asset/game/index.html`. The full VOIDRUNNER game is a
 * server-backed build (profiles, economy, leaderboards) and runs on its live
 * service; it had no public endpoint stood up for the APK, so no honest
 * full-game wiring existed for the shell yet. The bundled page is the game's
 * real front page (branding, pitch, controls) — never a placeholder and
 * never a fake game. It remains bundled in this build, byte-unchanged, but
 * is no longer the PLAY target.
 *
 * CUTOVER EXECUTED (2026-10-27, owner's ruling — the game goes IN the app
 * before the store submission; Option A): [GAME_URL] now points at the live
 * production game, https://voidrunner-2hm7p.ondigitalocean.app — the
 * artifact build of record, probe-verified field-equal to the artifact.
 * PLAY therefore opens the artifact itself: calibration screen, .skr
 * cabinet, and the mainnet-registration sign-in gate (a build whose game
 * surface admits an unregistered handle would NOT be the artifact). The
 * game is server-backed and requires a network connection; all in-game
 * funds remain simulated. The native side — wallet, menus, navigation,
 * lifecycle — and the [com.voidrunner.app.wallet.VoidrunnerWalletBridge]
 * JS bridge to the native MWA wallet (wired in GameScreen) are unchanged.
 */
object GameConfig {
    /** Live production game (Option A cutover, 2026-10-27 — see note above). */
    const val GAME_URL: String = "https://voidrunner-2hm7p.ondigitalocean.app/"

    /** Name the game uses to reach the native wallet: `window.VoidrunnerWallet`. */
    const val BRIDGE_NAME: String = "VoidrunnerWallet"
}
