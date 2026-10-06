# Rally for macOS

Native SwiftUI / AppKit application for macOS 13+, bundle ID `com.shiv.rally.macos`.
Behavior comes from `rallytv-beta`; visual references are the approved Rally artwork
and mockups. The window preserves Rally’s dark top navigation, cinematic hero, and horizontal media rails. Native menus,
Settings, sheets, and AVKit transport controls provide Mac interaction.

## Build and run

```shell
cd appleApp
swift build
swift test
swift run SelfTest --network
./packaging/package.sh 0.8.1
open dist-native/Rally.app
```

Full Xcode is required. SwiftPM resolves VLCKit and Sparkle. Packaging builds the
official icon, embeds frameworks/resources, verifies a local ad hoc signature,
and produces `dist-native/Rally.app` and a development DMG. Developer ID signing
and notarization remain release-owner steps; no signing identity is stored here.

## App and data

- Home: venue-photo hero, one live/recent-highlights rail, four upcoming games
  that expand into a guide as you scroll, and a balanced Browse by Sport grid.
- Live: real events plus the channel/Now–Next browser.
- Schedule: local dates, sport/league/status filters, saved games, live refresh.
- Event: Overview, Stats, Players, Plays, Sources and Highlights; game information,
  team form, pictured player leaders and published win probability. Unpublished
  data has an explicit empty state.
- Game View: centered score, fitted 16:9 player, compact transport controls,
  clickable Stats/Plays/Players/Sources, scoring moments and a compact context column.
- Multi-View: up to four streams, immersive layout, one audible stream with optional
  focus-following audio, and a player-stats tile grouped by unique game.
- Leagues, team centers, favorites, persistent watchlist, highlights and search.
- Settings: Stalker, Xtream, M3U, user-configured addons, curation, alerts,
  playback/accessibility, backups, diagnostics and updates.

ESPN IDs/endpoints are retained. Feed requests run three at a time; empty daily
feeds use Android’s monthly fallback, failed leagues retain cached data. Stremio
keeps manifest/event caches and bounded discovery/search, filtering premium/locked
entries. Search plays the selected stream; web-only results open browser coverage.
Credentials use Keychain; personalization uses UserDefaults and secret-free JSON
backup. No source is enabled by default and production views use real data.

## Playback

AVPlayer/AVKit handles HLS and ordinary video, including native volume, scrubbing,
fullscreen and picture-in-picture. Menus expose published quality caps and real
audio/caption tracks. Restart uses the available seek/DVR window; Live
Edge returns to its end. Unsupported DVR is explicitly disabled.

VLCKit handles clear DASH, transport streams and incompatible codecs. A loopback
relay preserves Cookie, Authorization, Origin and other allowed headers when VLC
cannot send them directly. Relative DASH BaseURLs, HLS references, ranges and
stream cancellation are preserved. Source failure and frozen playback clocks have bounded recovery and a manual
retry. Source switches cancel stale attempts and preserve pause, mute and volume. Compatibility playback applies the broadcast audio compressor;
AVKit retains the source’s native audio levels. Four-view playback prefers 720p,
with a two-tile limit on constrained hardware and one audible tile at a time.

## Keyboard and windows

⌘1 Home, ⌘2 Live, ⌘3 Schedule, ⌘4 Leagues, ⌘5 My Rally, ⌘6 Highlights,
⌘F Search, ⌘, Settings, ⌘R Refresh. During playback: Space play/pause,
←/→ seek ten seconds, M mute, S sources, ⌃⌘F fullscreen. Escape closes the
active transient panel, clip or fullscreen before leaving the player.

Minimum main window: 820×600 points. Default: 1440×900. Game View stacks below
1080 points and uses a context column above it. Cards support mouse/trackpad,
keyboard selection, hover and context actions.

QA arguments: `--tv=home|live|schedule|leagues|highlights|myteams`,
`--event=<id|first>`, `--play=<id|first>`, `--team=<league:id>`, `--game`,
`--settings`, `--stream=<http URL>`. `--visual-fixture` explicitly selects local
QA-only data; `--window=compact|standard|wide` selects 1040×700, 1440×900,
1720×1000. Production launch never selects fixtures. The optional in-app QA control
harness exists only in debug builds.

See [AFK stabilization validation](../docs/macos/STABILIZATION_VALIDATION.md) and [port completion validation](../docs/macos/FINISHING_VALIDATION.md) for executed
checks, screenshot comparisons and remaining hardware/account/distribution limits.
