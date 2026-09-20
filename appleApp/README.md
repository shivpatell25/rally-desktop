# RallyDesktop — macOS (SwiftUI)

Bundle ID: `com.shiv.rally.macos`. Windows (WinUI3) follows after macOS validates.

## Layout

- `appleApp/Package.swift` — SwiftPM: `RallyCore` (models, ESPN, Stremio, matcher, updates, theme, playback) + `RallyDesktop` (SwiftUI shell) + `SelfTest` (XCTest-free asserts) + `RallyDesktopTests` (XCTest, needs full Xcode).
- Android `app/` stays the reference implementation; `upstream` remote points at `shivpatell25/rally`.

## 1:1 ports (Android source → Swift)

| Swift | Android |
|---|---|
| `RallyCore/Models.swift` quality parser | `domain/model/Models.kt::parseQualityFromChannelName` |
| `RallyCore/StreamSelector.swift` | `domain/usecase/SelectBestStreamUseCase.kt` matching + `qualityRank` |
| `RallyCore/EspnClient.swift` leagues + base | `DataModule::provideEspnApi` (`site.api.espn.com/apis/site/v2/`) + `EspnRepositoryImpl::espnLeagues` |
| `RallyCore/StremioClient.swift` | `data/remote/stremio/StremioApi.kt` + `StremioRepositoryImpl.kt` (header allowlist, `isDirectPlayable`) |
| `RallyCore/UpdateChecker.swift` | `data/update/RallyUpdateManager.kt` (`compareVersions`, GitHub Releases; macOS downloads DMG instead of APK install) |
| `RallyCore/RallyTheme.swift` | `presentation/theme/AppleTvTheme.kt` hex tokens, `CardFocusScale` 1.025 |

Rules kept: 4-tile Multi-View @720p30, evidence-based quality labels (never guess 4K/HDR), default addon `https://sports.highfly.to/manifest.json`.

## Build (Xcode 27.0)

```
cd appleApp
swift build   # PASS, VLCKit + Sparkle2 resolved
swift test    # 6/6 PASS — quality, matcher, versions, VLC cap + headers
```

Playback: `VlcEngine` (4-tile cap, UA/Referer forwarding) primary, AVPlayer fallback for plain HLS.
Updates: `SparkleUpdater` (feed `appleApp/appcast.xml`) primary, GitHub-Releases `UpdateChecker` fallback.

## Still needed from you

1. Team ID when ready to sign `com.shiv.rally.macos`; `.app` packaging sets `SUFeedURL` to the appcast URL.
2. `sparkle:edSignature` keypair (`./bin/generate_keys`) before first DMG release.

## Next

DMG + notarization → Windows WinUI3 port.
