# macOS AFK stabilization — October 3, 2026

The AFK screen now observes actual activity in Rally's own window and window activation. Returning from another app wakes Rally without activating an underlying control. The full-window overlay uses responsive rows and an official wordmark, covers the titlebar cleanly, and avoids expensive blur or a fixed window-size frame.

## Runtime verification

- Entered and exited AFK using a shortened debug-only idle interval.
- Keyboard activity over repeated idle intervals kept Rally awake.
- Switching to another application entered the inactive state; activating Rally woke it.
- Wake click was consumed; the Home route and underlying state stayed unchanged.
- Resized before and during AFK, including 820×600 and 1440×900 windows.
- Entered native fullscreen while AFK, exited AFK, then returned to windowed mode.
- Confirmed the titlebar seam was removed and clock, wordmark and score rows remained inside the window.

Screenshots: [standard](stabilization-qa/afk-standard-final.png), [minimum window](stabilization-qa/afk-compact-final.png), [fullscreen](stabilization-qa/afk-fullscreen.png), [inactive window](stabilization-qa/afk-inactive.png), [after wake](stabilization-qa/afk-wake-final.png).

98 tests passed, with zero failures. Debug and Release builds succeeded. The running app was replaced with the normal Release build after testing, without the shortened idle interval or QA flags.

Local artifact: [Rally 0.7.1 development DMG](/Users/shiv/Desktop/rally-desktop/appleApp/dist-native/Rally-0.7.1-macOS-development.dmg). DMG checksum verification and strict app signature verification passed. SHA-256: `8346ad0a1b07a9bbea70b00f44f686314393d853acade64e66e6b64dcb60677a`.

This is a local ad-hoc development build. Developer ID signing and notarization were not performed. This report covers AFK stabilization; it supplements the earlier port-completion report and preserves unrelated existing work in this checkout.
