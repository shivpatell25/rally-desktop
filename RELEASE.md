# Rally Release Process

GitHub Releases is Rally’s distribution channel for Android TV beta packages and
the macOS/Windows desktop builds.

## Required repository secrets

- `RALLY_KEYSTORE_BASE64`: base64-encoded contents of the Rally release keystore
- `RALLY_KEYSTORE_PASSWORD`: keystore password
- `RALLY_KEY_ALIAS`: release alias (`rally` for the current key)
- `RALLY_KEY_PASSWORD`: private-key password

The keystore itself must also be kept in a separate encrypted backup. Every update to the installed app must be signed by this same key.

## Publish

1. Increment `versionCode` and `versionName` in `app/build.gradle.kts`.
2. Merge a green Android CI build to `main`.
3. Create a GitHub prerelease and tag such as `v1.0-beta2`.
4. Upload the locally verified signed APK, or manually run the signed-release workflow for that tag after configuring the repository secrets.
5. Verify the APK signature and SHA-256 digest before announcing the release.

## Desktop releases

macOS and Windows share one version/tag train in `shivpatell25/rally-desktop`.
For macOS, run `swift test` in `appleApp/`, then
`./packaging/package.sh <version>`; this produces an ad-hoc signed development
DMG. For Windows, run `windowsApp/packaging/package.ps1 -Version <version>` on
Windows with Visual Studio/MSBuild and the Windows App SDK installed, for both
`-Arch arm64` and `-Arch x64`. That produces self-contained portable ZIPs. The
Windows ZIPs are unsigned unless a local signing certificate is explicitly
used. Run both apps from the produced packages before publishing all three
assets and a SHA-256 manifest on the matching `v<version>` release.

The macOS package is not notarized; macOS may require the user to approve or
open it manually. The Sparkle signing key authenticates staged in-app updates;
it is not an Apple Developer ID certificate and remains local. Android signing
secrets are configured only in the Rally TV repository.

Never commit a keystore, password, provider credential, local properties file, or APK.
