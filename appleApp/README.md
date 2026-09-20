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

## Build now (Command Line Tools only)

```
cd appleApp
swift build          # PASS
swift run SelfTest   # PASS (10 asserts)
swift test           # needs full Xcode — XCTest not in CLT
```

## Still needed from you

1. Full Xcode from the App Store (`xcodebuild` fails on CLT-only). Unlocks: `swift test`, SwiftUI previews, `VLCKit` + `Sparkle2` SPM deps, signing (`com.shiv.rally.macos`), notarization, DMG.
2. Apple Developer Team ID when ready to sign.
3. `brew reinstall` of CLT (`sudo rm -rf /Library/Developer/CommandLineTools; sudo xcode-select --install`) — current CLT is arch-mismatched, so `brew install` builds from source and fails; VLC cask + Temurin JDK17 binary worked around it.

## Next

VLCKit playback target → Sparkle2 in-app updates → DMG + notarization → Windows WinUI3 port.
