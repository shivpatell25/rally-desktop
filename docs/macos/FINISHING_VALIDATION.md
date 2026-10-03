# macOS completion validation

October 2, 2026 · Android TV Beta 11 reference · Apple Silicon, macOS 26.6.2 / Xcode 27.
This report supersedes the earlier parity reports. The work preserves existing
backend integrations and the user's previous desktop changes; the Windows port
was not edited during this completion pass.

## Delivered locally

- `appleApp/dist-native/Rally.app`, version **0.7.0**.
- `appleApp/dist-native/Rally-0.7.0-macOS-development.dmg`.
- Debug and release builds succeed. **98 tests, zero failures** on the final source.
- Ad hoc bundle signature passes deep/strict verification. DMG checksum verification passes.
- Inter/Sora, the current Android background, official branding and embedded playback/update frameworks are present.
- The release binary excludes the opt-in debug UI control harness.
- The packaged release launches on Home with real data; no fixtures or configured provider are required to browse.
- macOS source/doc changes pass whitespace checking. No GitHub publication was performed.

DMG SHA-256: `f8f9c8be4fda929b9ecaef21902a4125457972dfb8fde2c9c94ca748f6eaac7f`.

## Corrected parity and behavior

| Area | Implemented and inspected |
| --- | --- |
| Shell | Persistent wordmark and all six tabs, neutral rounded selection, seamless dark flare; native windows/menus/Settings, keyboard and mouse input |
| Home | Venue-photo hero; centered scores over actual team colors; one live/highlight rail; same four upcoming games morph from compact previews into rows; balanced sports including both college leagues, soccer and tennis; Home returns to top |
| Event | Actual venue photograph, Players replaces Lineups/injuries, balanced pictured leaders, meaningful team comparisons, full published player tables; Overview/Stats/Players/Plays/Sources/Highlights; published win probability only |
| Game View | Centered score, 16:9 fitted player, seven aligned controls, clickable sidebar tabs, compact real team/player stats and latest plays; scoring moments open play details; aligned standard-window context and moments |
| Player | Fullscreen R and transient controls, Game View/diagnostics, real track/quality choices, Restart, source picker; generation guards, source cancellation, bounded frozen-clock recovery, retained pause/mute/volume and teardown |
| Multi-View | Streams retain sessions during layout changes, fitted tiles, immersive zero-gap geometry, one audible stream with optional focus-following, stats grouped by unique game; RedZone same-day daytime NFL expansion |
| Other destinations | Live/channel browser, Schedule/date/filter rows, real Highlights, My Rally, Search, league/team destinations and Settings retained; League Center compact games/standings rows, correct Today filtering and canceled-date guards |
| Small windows | Native resizing remains available; Game View stacks vertically; sports grid wraps symmetrically; content scrolls naturally when it exceeds available height |

The [comparison gallery](finishing-qa/comparison.html) shows actual running-app
captures alongside current Android references. Current user refinements (team
logo artwork, glass tabs, Players, no redundant Home rails) supersede conflicting
elements in the original mockups. Data and window aspect ratios differ, so this
is a composition/component comparison, not a claim of pixel-identical responsive
screens.

## Executed playback and UI checks

- Real ESPN scoreboard/schedule/summary requests and football plays/statistics;
  actual Home arena photo and playable highlight URLs.
- Network smoke test: **SELFTEST PASS** and **NETWORK / PLAYBACK SMOKE PASS**.
  Public HLS reached ready state and advanced its clock; published audio,
  captions and quality variants, track selection, forward seek and restart passed.
- Clear DASH reached playback through the authenticated compatibility relay,
  advanced its clock, exposed published tracks/qualities and passed VOD seek.
- In the packaged debug app, native clicks exercised Game View controls/sidebar,
  source switching, resume/restart and diagnostics. Switching retained pause;
  resuming advanced the new source's clock.
- Three simultaneous HLS sessions continued through Multi-View/immersive layout
  changes. Selecting a different audio tile muted the previous one; enabling
  focus-following and moving focus selected exactly one audible stream. Leaving
  Multi-View for Game View removed its sessions.
- Home top/guide, native small-window layout, nav destinations, football Event
  Players/Plays, source picker, Settings M3U/Viewing and League Center were
  captured. Search, My Rally, live/schedule and saved-event actions were exercised
  during the completion pass. Settings credentials were not changed for QA.
- Tests cover all-player category merging, scoring-play preservation, frozen
  clock retry policy, immersive geometry, RedZone selection and game deduplication,
  in addition to existing provider, persistence, playback and desktop contracts.

UI automation uses actual native mouse/key events and an opt-in debug-only
app-owned capture harness. GPU video layers appear black in those snapshots;
readiness, progressing clocks and playback checks are separate evidence. Native
AVKit video controls are intentionally retained for Mac scrubbing, volume and PiP.

## Remaining verification and distribution limits

- Paid Stalker/Xtream/M3U accounts were not configured for this run. Their parsing,
  header/authentication and persistence paths have fixture tests; account-specific
  EPG and broadcasts require working credentials. No desktop DRM license exchange
  was added.
- Minimum macOS 13, Intel and constrained hardware were not available for execution.
- The final live feed contained an NHL game. The no-live Home highlight branch
  was inspected and real highlight loading was exercised, but a final forced
  no-live feed was not used to certify that runtime state.
- Multi-View checks used three public HLS sessions. RedZone slate logic and game
  deduplication have tests; an actual RedZone subscription was not available.
- APIs sometimes omit venue photos, predictors, broadcasts or statistics. Missing
  data stays explicit; no prediction or player statistics are invented.
- These are local development artifacts. Public macOS distribution needs a
  Developer ID signature and notarization; neither identity was provided here.
