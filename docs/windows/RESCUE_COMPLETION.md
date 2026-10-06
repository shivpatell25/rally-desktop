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
| Schedule | Native date/sport/league controls and event rows visible; duplicate Save control removed; filter interaction pending |
| Event hero | Full-width artwork restored; tab strip and Watch/Save controls render |
| HLS public VOD | Actual Mux Big Buck Bunny sample decoded; 634-second timeline; seekable; no false live timeline; Watch from Start enabled |
| Quality selection | Manifest choices Auto/1080/720/480/288/184; switched while paused; decoder reports 848×480, paused at 18s after prior 21s position (keyframe rounding) |
| Audio controls | Native track shown; keyboard volume changed to 99%; Mute visibly toggled on/off |
| Caption absence | Public HLS sample has zero captions; dialog accurately reports no tracks |
| Picture-in-Picture | Native small window opens; Escape restores normal player window; crowded controls found and repaired, recheck pending |
| Real sports API parsing | Current ESPN NFL scoreboard and summary fetched over verified HTTPS; fixture regression verifies form, injuries, venue and stats |

Remaining runtime checks: real-data app screens, all settings categories, save/remove/relaunch persistence, schedule filters, game panels, native source switching/retry, live HLS and DASH decoding, published alternate audio/captions, fullscreen, repaired PiP, compact resizing and Windows scaling at 100/125/150/200 percent. Hardware decoding and multiple physical monitors cannot be certified from this software-rendered VM. No provider credentials are used.

### Current native validation session

Windows scaling changed through the native Display settings from 125% to 100%. Home renders at 100%, including navigation, hero and event rails. Other screens at 100% and remaining scale levels still need checks. VM display connection stalled during further checks; the guest and read-only app diagnostics remained responsive. The display recovered after a VM restart. Windows is at its PIN sign-in screen; the user has been asked to unlock it for remaining interactive checks. An isolated DEBUG real-data profile is now available for validating production APIs without altering the normal Rally profile.

Both self-contained Release payloads publish successfully on Windows: win-arm64 and win-x64. The executable and Rally.App.pri are present in each payload. Latest core test rerun: 66 passed, zero failed. Release launch and remaining manual checks are still pending. The later playback ordering fix covers resume and final recovery. It is included in successful fresh Debug ARM64 and Release ARM64/x64 builds; interactive runtime validation remains pending.

Release payload inspection confirms DEBUG test fixtures are excluded and each package contains libvlc.dll for its own architecture. The temporary QA auto-start task was removed. Current rescue checkpoint is on `codex/windows-rescue`; no rescue release has been published. The VM still needs unlocking, and its display scaling is currently 100% (restore 125% after completing scale checks).
