# Rally Release Process

GitHub Releases is Rally’s distribution channel for signed Android TV beta packages.

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

## macOS releases

The macOS 0.7.1 release includes the completed native port and AFK stabilization.
Run `swift test` in `appleApp/`, then `./packaging/package.sh 0.7.1`.
Verify the app signature and disk image, sign the exact DMG with the existing
Sparkle Ed25519 key, and publish its enclosure/signature in `appleApp/appcast.xml`.
Publish the DMG and checksum in `shivpatell25/rally-desktop`; keep Windows work
separate until its own validation/release is requested.

The current package has an ad-hoc development signature and is not notarized.
The Sparkle signing key authenticates updates; it is not an Apple Developer ID
certificate. It remains local and is not stored in GitHub secrets. Android
signing secrets are configured only in the Rally TV repository.

Never commit a keystore, password, provider credential, local properties file, or APK.
