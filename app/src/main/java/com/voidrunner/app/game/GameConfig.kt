package com.voidrunner.app.game

/**
 * How the game content reaches the APK.
 *
 * *** MORNING DECISION — see README "Open decision: game content". ***
 *
 * Option A — HOSTED_URL (simplest): the WebView loads a public game URL.
 *   Set GAME_URL below. Needs the game publicly reachable; weakest story
 *   against the hackathon's "no web wrappers" rule.
 *
 * Option B — BUNDLED_ASSET (best offline): a static export of the game lives
 *   under app/src/main/assets/game/, loaded as
 *   "file:///android_asset/game/index.html". Needs a static build of the game.
 *
 * Option C — HYBRID (recommended): bundled game (B) + the [VoidrunnerWallet]
 *   JS bridge to the native MWA wallet. Native wallet, native menus, native
 *   navigation — the game is content, the app is an app.
 */
object GameConfig {
    /** Placeholder until the morning decision lands. CI builds will still compile. */
    const val GAME_URL: String = "https://voidrunner.example.invalid"

    /** Name the game uses to reach the native wallet: `window.VoidrunnerWallet`. */
    const val BRIDGE_NAME: String = "VoidrunnerWallet"
}
