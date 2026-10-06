# Windows rescue audit — October 5, 2026

The prior completion report is historical. These initial statuses describe inspected implementation, not successful runtime validation. This matrix is the active repair plan; completion requires new Windows runtime evidence.

| Area | Initial status | Repair / evidence needed |
| --- | --- | --- |
| Home | Partially working | Cache and refresh races; refreshed hero/card scores; Browse by Sport discoverability; personalized rail |
| Live events | Partially working | No periodic score refresh or initial loading; distinguish feed failure from empty |
| IPTV / channels / guide | Partially working | Provider failure visibility; guide freshness; real configured sources |
| Schedule | Partially working | Sport filter separate from league; state restoration; all failed feeds silently appear empty; row status |
| Leagues / standings | Partially working | Concurrent tab responses overwrite current tab; empty teams; standings response parsing |
| Team hub | Partially working | NFL grouped roster parser; actual team schedule; injuries and honest empty/error states |
| My Rally | Partially working | Immediate shared state notifications; saved removal and refreshed saved scores |
| Search | Partially working | Only teams from today's matching games; no league results; preserve query/navigation; partial results on failures |
| Settings | Partially working | Required categories; old addon wording; legal help text; draft retention; updates failure states |
| Event details | Partially working | Detail failure currently blocks hero; no live refresh; missing Lineups/Highlights/injuries; stale Sources response |
| Game view | Partially working | Responsive columns; full stats scroll; races in refresh/open; useful playback errors |
| Video playback | Partially working | Shared WinUI/VLC output retained; request ordering race; startup errors and source fallback |
| Source selection | Partially working | No auto-play of unverified channel matches; renew source list; actual error actions |
| Quality selection | Missing | Manifest-published quality choices; preserve position/pause and headers |
| Captions / audio | Partially working | Track selection feedback; persistence across recreation; no fabricated tracks |
| Watch from start / live edge | Broken | VOD-style seek/restart applied to live; bounded seekable window; Jump to Live |
| Key moments / other games | Partially working | Empty states; fresh live data; direct published clips only |
| Stats / leaders / team stats | Partially working | Truncated stats; nested parsing errors; responsive readable rows |
| Lineups | Missing | Real reported lineups; roster explicitly labeled fallback |
| Plays / players / current drive | Partially working | Full lists and loading/failure distinction; refresh correctness |
| Favorites / watchlist | Partially working | Shared change notification; route restoration and immediate removal |
| Provider / addon settings | Partially working | Validate/test manifests; source invalidation; IPTV disclaimer; errors |
| Loading / empty / error | Broken | Cancellation can leave spinner; stale loaders overwrite newer ones; API failures disguised as no content |
| Updates | Partially working | Error indistinguishable from up to date; duplicate download buttons; architecture release matching |
| Persistence | Partially working | Shared preferences retained; favorite toggle atomicity; preferences import notification |
| Navigation | Partially working | Focus keyed only by page type; scroll/query/filter state not restored; typed route validation |
| Deep links | Partially working | Bypasses shared repository; team route missing; activation routing |
| Windows shell / resizing / DPI | Partially working | Physical vs logical window sizing; small work areas; 100/125/150/200% validation |
| Hover / press / focus | Partially working | Disabled unsupported controls; nested reminder hit routing; consistent states |
| Fullscreen / compact overlay | Partially working | Escape and layout state; live-aware controls; player errors |
| Multiview | Partially working | Concurrent add capacity; retained audio owner; toolbar/tile overflow |
| PiP | Missing | Native CompactOverlay presenter, with fallback if unsupported |
| Performance / resources | Partially working | Coalesced detail requests; bounded caches/images; disposed native sessions; extended navigation |
| Production data | Working by code inspection | Fixtures guarded by DEBUG; audit Release payload and real sports/provider playback |
| Branding | Partially working | Official assets retained; responsive layout without clipping or generic blue accents |

Repair order: data/state/cancellation and parsing → build/core checks → routes and loading → playback/live policy → complete feature screens/settings → native Windows runtime, resize and DPI validation → portable packages. No claim of completion is based solely on screenshots or historical reports.

## Repair implementation and fresh checks

The foundation and feature changes are implemented. Final runtime validation is still in progress; this document does not mark the rescue complete. Public samples only are authorized for stream validation.

- Data: bounded shared request caches, cancellation isolation, feed failure/empty distinction, grouped rosters/standings, reported lineups, team schedules/form/injuries, actual score shapes.
- State/navigation: shared save/follow notifications, atomic persistence and visible write failures, route-specific query/filter/tab/scroll/focus restoration, invalid route fallback, desktop shortcuts.
- Playback: ordered source opens, verified source matching, native decoder recovery, actual HLS/DASH quality discovery, track selection, source renewal, seek limits, live edge policy, native fullscreen and CompactOverlay.
- Screens: refreshed Home/Live, schedule filters, complete search groups, all event/game panels with real-data or intentional unavailable states, responsive settings categories and provider drafts. Both source configuration areas contain the requested legal help text and Addon Manifests wording.
- Resources: bounded decoded images and addon caches, retained shared services, unload cancellation, disposed player sessions, fresh guide updates without rebuilding the channel list.

### Evidence collected in this rescue

| Check | Result / scope |
| --- | --- |
| Core regression suite | 66 tests passed on both macOS and Windows ARM64 on .NET 8, including 14 rescue regressions; real NFL summary response fixture included |
| Native Windows build | Latest Debug ARM64 build succeeds, including save-failure tracking, quality-switch ordering, compact playback controls, and responsive moments |
| Native launches | Repeated launches succeed in Windows 11 ARM64 VM |
| Home/event/game navigation | Keyboard Watch opens game; event cards open detail; Back and Home shortcuts operate |
| Search | Typed Chiefs query returns grouped games/teams/sources; team opens; Back restores query and result focus |
| Schedule | Native date changed Oct 6 → Oct 5; Baseball/MLB filters return real final games; event opens; Back restores date, filters and row focus |
| Event hero | Full-width artwork restored; tab strip and Watch/Save controls render |
| HLS public VOD | Actual Mux Big Buck Bunny sample decoded; 634-second timeline; seekable; no false live timeline; Watch from Start enabled |
| Quality selection | Manifest choices Auto/1080/720/480/288/184; switched while paused; decoder reports 848×480, paused at 18s after prior 21s position (keyframe rounding) |
| Audio controls | Native track shown; keyboard volume changed to 99%; Mute visibly toggled on/off |
| Caption absence | Public HLS sample has zero captions; dialog accurately reports no tracks |
| Picture-in-Picture | Native small window opens; Escape restores normal player window; crowded controls found and repaired, recheck pending |
| Real sports API parsing | Current ESPN NFL scoreboard and summary fetched over verified HTTPS; fixture regression verifies form, injuries, venue and stats |

Remaining runtime checks: real-data app screens, all settings categories, save/remove/relaunch persistence, schedule filters, game panels, native source switching/retry, live HLS and DASH decoding, published alternate audio/captions, fullscreen, repaired PiP, compact resizing and Windows scaling at 100/125/150/200 percent. Hardware decoding and multiple physical monitors cannot be certified from this software-rendered VM. No provider credentials are used.

### Current native validation session

Native Display settings have been checked at 100%, 125% and 150%. At 150%, Home, Schedule, league standings/team hubs, Search, My Rally, event detail and Settings render and accept keyboard input. The long UFC Home hero exposed clipped status/action text; its height now grows to fit the actual title and controls. The 200% pass and remaining player layouts are pending. VM display connection stalled during earlier checks; the guest and read-only app diagnostics remained responsive. The display recovered after a VM restart and the user unlocked Windows. Interactive validation has resumed. An isolated DEBUG real-data profile is now available for validating production APIs without altering the normal Rally profile.

Both self-contained Release payloads publish successfully on Windows: win-arm64 and win-x64. The executable and Rally.App.pri are present in each payload. Latest core test rerun: 66 passed, zero failed. Release launch and remaining manual checks are still pending. The later playback ordering fix covers resume and final recovery. It is included in successful fresh Debug ARM64 and Release ARM64/x64 builds; interactive runtime validation remains pending.

Release payload inspection confirms DEBUG test fixtures are excluded and each package contains libvlc.dll for its own architecture. The temporary QA auto-start task was removed. Current rescue checkpoint is on `codex/windows-rescue`; no rescue release has been published. The VM is unlocked, and its display scaling is currently 150% (restore 125% after completing scale checks).

### Continued playback validation after unlock

- Rolling public HLS: native decoding succeeds (512×288, 30 fps), with an 80-second reported rewind window. Jump to Live seeks successfully and the UI reports the live edge. Extended playback exposed VLC reporting absolute time beyond its original window length. The repair disables invalid rewind instead of clamping to that stale window; Jump to Live reconnects when a verified seek range is unavailable. Regression passes; native extended recheck passed at 111 seconds playback against a reported 74-second window: the UI disables rewind, keeps decoding, and offers reconnect via Jump to Live.
- DASH: public Akamai Big Buck Bunny MPD decodes natively, reports 634-second VOD duration, and records no playback recovery errors.
- Fullscreen: F11 opens fullscreen and Escape returns to the normal window.
- Repaired PiP: native CompactOverlay renders Play/Pause, live action and Return to Window without clipped controls at 100% scaling.

### Real-data and settings interaction pass (October 6)

- Home/API: current sports feed loads, including a long UFC event title; repaired hero shows complete status, metadata, venue and More Info action at 150%.
- My Rally: saved basketball event survived app launches and VM restart; updated final score loads; Remove immediately returns the intentional empty state.
- Leagues: NFL standings show 32 teams with current records; team cards open team hubs; Cardinals schedule, roster (82 feed entries) and injuries load. Follow updates immediately and appears in Account.
- Search: real Chiefs query groups game and team results; team opens; Back restores query and result keyboard focus.
- Account: native Save As and Open pickers export and import preferences successfully.
- Playback/Appearance: keyboard toggles are reachable and scroll into view; Home sport enable/disable works. Sport reordering exposed lost focus after rebuilding the panel; interaction preservation is repaired, native recheck pending.
- IPTV: public M3U sample entered through the UI; Save & Test reports “Connected · 3 channels.” No credentials used.
- Addon Manifests: public sample manifest entered through the UI; Save & Test reports one connected, zero unavailable/invalid. Both configuration areas show the exact requested legal help text.
- Updates: live GitHub check reports installed 0.8.0 current; Open Releases launches the correct repository release page.
- About: support information copies successfully with the credential-exclusion status.

This is ongoing validation. Latest track restoration/replay/live-window fixes, Settings reorder focus, notifications, source switching/recovery, game panels, 200% scaling and fresh Release launch checks remain pending.

### Display interruption and current checkpoint

The VM display and guest agent stalled while Windows Display settings were open over the rolling HLS player. This prevented the reconnect button and 200% checks. Quitting/reopening the UTM controller recovered the VM; Windows now requires the user to sign in. UTM automatic display resizing is temporarily disabled so native resolution selection can be checked after sign-in; restore it after DPI validation, together with the original 125% scaling. This VM failure does not establish a Rally crash; further runtime testing is required.

The shared refresh helper now waits for measured replacement controls, preserves all scroll viewers, and cancels focus restoration if the user has moved on. Settings sport reordering uses this helper. Live TV retains guide containers when the displayed Now/Next programs have not changed; actual guide changes preserve interaction. DEBUG read-only snapshots now include native toggle values, date selectors, list items and open dialogs, excluding editable values and credentials. Native rechecks are pending. Latest macOS core regression rerun: 66 passed, zero failed.

Native core regression rerun after recovery: 66 passed, zero failed. Latest Debug ARM64 compiles the window-wide input version guard; delayed refresh and Back restoration stop when the user interacts anywhere in the window, including the top navigation. Both Release architectures have published successfully during this pass; the final rebuild for that guard succeeded on both architectures. Release fixture exclusion and VLC architecture checks passed for both payloads. The exported native preferences file contains followed teams, saved games and preferences only; no source credentials.

After the user signed in, native interactive validation resumed. Final Release ARM64/x64 package inspection passed again: app/resources present, correct VLC architecture, DEBUG fixtures excluded. A separate TranslucentTB startup diagnostic appeared and was dismissed; it was not a Rally error.

### October 6 continuation

- Windows 11 at 200% display scaling: Home hero grows for the long event title, status and actions; Settings sections and sport reorder controls remain usable. Repeated NFL reorder actions retained keyboard focus. Live TV search/category/refresh and the three public channels render.
- A public rolling HLS channel played at 512×288/30 fps after navigating from Live TV by keyboard. Watch from Start and Jump to Live both moved playback within the source's rolling window. During the extended run, VLC's timeline reset to zero while decoded video continued; the app retried despite advancing video. Playback health now accepts advancing decoded frames independently from the VLC clock and disables live seeking after the clock has been stale for five seconds. A new core regression covers that disabled seek state. The fix was rechecked in the native Windows player: video continued past the stale duration, rewind disabled, and Jump to Live reconnected with zero recovery failures.
- Latest host core suite: 67 passed, zero failed. A fresh Windows native Release build succeeds for ARM64 and x64. Both payloads contain the app and resources, exclude DEBUG fixtures, and include the correct architecture of VLC. A macOS cross-build cannot run Microsoft's Windows XAML compiler.
- The Windows VM restarted to its sign-in screen during the playback check. Native Release launch, live timeline recheck, track/source tests, scale restoration and final interaction checks need an unlocked desktop. No PIN was entered. Windows scaling and UTM automatic display resizing still need to be restored to the prior 125%/enabled values after that pass.

The repair remains in progress. The live-clock health change and regression test are committed on `codex/windows-rescue`. The 0.8.1 desktop release is published with the rebuilt Windows ARM64/x64 packages and the macOS development DMG; the remaining audit items below are still open.

### Signed-in Release verification (October 6)

- The signed-in Windows session launched the latest ARM64 Release payload. Home loaded current Rally sports data; Search returned the real Chiefs–Raiders final (30–27), and opening the result reached the matching event detail page.
- A public highlight opened the player and surfaced Retry / Pick Source after its URL had expired. This verifies the recoverable playback error path, not successful decoding of that clip. Public DASH VOD and rolling HLS decoding were validated separately above.
- The Windows native Release builds for ARM64 and x64 were rebuilt after the live-clock repair and inspected for XAML resources, architecture-matched VLC and absence of DEBUG fixtures. Both packages are published in [Rally Desktop 0.8.1](https://github.com/shivpatell25/rally-desktop/releases/tag/v0.8.1).
- macOS regression suite: 98 passed. The 0.8.1 development DMG was built from the current source; it is ad-hoc signed and not notarized.
- Native Windows Display Settings has been restored to the prior 125% scaling after the 150% Release UI pass. UTM automatic display resizing remains disabled pending a final VM cleanup.

### Post-release stabilization continuation

- The native Windows screen was still signed in and displaying Rally. A route transition exposed a timing risk in the ambient score overlay: its sports-feed request could finish after navigation, and the overlay was not rechecking whether the current screen still allowed it. Navigation now invalidates any pending idle request, and the route eligibility is checked again after the request completes. The DEBUG QA snapshot now reports whether the idle overlay is visible.
- Windows Core regression suite: 67 passed, zero failed. The current UTM guest command channel timed out while checking the native UI, so this follow-up has not yet been rebuilt or interactively rechecked in Windows. GitHub Actions is the next native build gate.
- This stabilization change is on `codex/windows-rescue`; the published 0.8.1 assets remain the prior release and do not contain this follow-up. The broader rescue audit remains open.
