
<img src="Rally_Brand_Kit/02_Wordmark/rally_wordmark_color_transparent_1024.png" alt="Rally wordmark" width="320">

Rally for macOS and Windows. A sports hub that combines ESPN schedules and live data with the user's Stalker/Ministra, Xtream, or M3U IPTV source and configured Stremio addons, then presents matching streams in a cinematic interface. The macOS app combines Rally’s visual identity with native toolbar navigation, menus, settings, AVKit playback, and responsive desktop layouts.

The Android TV implementation is retained under `app/` as the reference platform (`upstream` remote).

## Features

- Live and upcoming NFL, NCAAF, NBA, NCAAB, MLB, NHL, soccer, and college events
- Rally home dashboard, event detail, league center, highlights, and game view
- Automatic matching between events and IPTV channels with evidence-based quality labels
- Stalker/Ministra, Xtream Codes, and M3U IPTV provider support
- Stremio addon stream discovery with header allowlisting and source switching
- Full-screen playback, in-app updates, and up to four-stream Multi-View
- ESPN highlight clips, venue/weather/editorial metadata, player headshots, leaders, team comparisons, and formatted stat tables
- Searchable live-TV channel browser with Now/Next EPG
- Local caching for channels, manifests, streams, and sports data
- Keyboard/trackpad/mouse-first on desktop (arrow-key D-pad walk, two-finger or drag shelf paging, space pauses)

## Layout

- `appleApp/` — macOS SwiftUI app (SwiftPM: `RallyCore` library, `RallyDesktop` app, `SelfTest`, `RallyDesktopTests`)
- `windowsApp/` — Windows solution (`Rally.sln`: `Rally.Core` net8.0 library, `Rally.App` WinUI 3 app, `Rally.Tests` xUnit)
- `app/` — Android TV reference implementation
- `Rally_Brand_Kit/` — wordmarks, marks, backdrops, brand tokens

## macOS

Bundle ID `com.shiv.rally.macos`, macOS 13+.

Requirements: full Xcode (macOS SDK; CLT-only builds the core but not tests or signing), SwiftPM (no extra installs — VLCKit and Sparkle 2 resolve via SPM).

```shell
cd appleApp
swift build          # RallyCore + RallyDesktop
swift test           # unit suite (quality, matcher, providers, updates, summary)
swift run SelfTest   # dependency-free assert pass
```

Debug deep links for verification: `--tv=home|live|schedule|leagues|highlights|myteams`, `--league=NFL`, `--event=<id|first>`, `--play=<id|first>`, `--team=<league:id>`, `--game`, `--settings`, `--skip-onboarding`. Add `--visual-fixture` for stable local sports data and `--window=compact|standard|wide` for deterministic responsive captures. Notifications and browsers can also open `rally://event/<id>` and `rally://team/<league:id>`.

Unsigned dev package (signed/notarized DMG needs a Team ID):

```shell
./packaging/package.sh 0.7.1   # dist-native/Rally.app + development DMG
```

In-app updates check `appleApp/appcast.xml` via Sparkle 2 (`SparkleUpdater`), with the GitHub Releases API as fallback (`UpdateChecker`). The Sparkle public key is staged at `appleApp/sparkle_public_key.txt`; the private seed stays out of git (`~/.config/rally-macos/sparkle_private_key`). First signed DMG release adds the enclosure + `edSignature` to the appcast.

## Windows

Requirements: .NET 8 SDK (`windowsApp/global.json` pins it), VS 2022 with WinAppSDK 1.7 workload for `Rally.App` (WinUI 3, unpackaged, `VideoLAN.LibVLC.Windows` playback).

```shell
cd windowsApp
dotnet test tests/Rally.Tests -c Release   # core suite
```

`Rally.Core` (models, ESPN, Stremio discovery, Stalker/Xtream, resolver, DPAPI-backed settings) builds and tests anywhere .NET 8 runs. `Rally.App` builds on Windows only; CI (`windows.yml`, windows-latest) builds the solution with MSBuild and runs the tests.

## Setup

Open Settings → Sources and choose the IPTV provider. For Stalker/Ministra, enter the portal URL and MAC address supplied by the provider. For Xtream Codes, enter the server URL, username, and password supplied by the provider. Provider details are runtime settings and do not require source edits. Stremio addon manifest URLs can be added from the same screen (a sports addon is preconfigured for testing).

HTTP portals are supported because some legacy Stalker providers do not offer TLS. The settings screen warns when a portal is unencrypted. Prefer HTTPS whenever the provider supports it because HTTP credentials and viewing traffic can be intercepted on the network.

## Performance profile

- Home content appears without waiting for the IPTV catalog
- Duplicate network loads are coalesced and short-lived caches reduce repeated requests
- Bundled backdrops bypass the network image pipeline
- Image, player, and Multi-View buffers are bounded
- Multi-View streams are capped at four tiles
- Release desktop builds strip debug symbols and exclude build caches

## Data and privacy

The app does not ship IPTV credentials. Secrets live in Keychain (macOS) or DPAPI-protected storage (Windows). Tokens are not written to logs, release HTTP logging is disabled, and request headers from third-party stream addons are allowlisted before playback. Users are responsible for using subscriptions and addons they are authorized to access.

See the full [privacy policy](PRIVACY.md) and [content/provider disclosure](CONTENT_SOURCES.md).
