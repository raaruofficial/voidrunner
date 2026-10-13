package com.voidrunner.app.game

/**
 * How the game content reaches the APK.
 *
 * DECISION (2026-10-12) — Option B wiring, honest scope:
 * The WebView loads the bundled front page at
 * `file:///android_asset/game/index.html`. The full VOIDRUNNER game is a
 * server-backed build (profiles, economy, leaderboards) and runs on its live
 * service; it has no public static export, so no honest full-game bundle
 * exists for this shell yet. The bundled page is the game's real front page
 * (branding, pitch, controls) — never a placeholder and never a fake game.
 *
 * Production cutover (queued, owner's call): when the live game endpoint is
 * stood up for the APK, point [GAME_URL] at it (Option A) or ship a hybrid
 * (Option C: bundled shell + the [com.voidrunner.app.wallet.VoidrunnerWalletBridge]
 * JS bridge to the native MWA wallet, already wired in GameScreen). The
 * native side — wallet, menus, navigation, lifecycle — is complete either way.
 */
object GameConfig {
    /** Bundled front page shipped inside the APK (see decision note above). */
    const val GAME_URL: String = "file:///android_asset/game/index.html"

    /** Name the game uses to reach the native wallet: `window.VoidrunnerWallet`. */
    const val BRIDGE_NAME: String = "VoidrunnerWallet"
}
