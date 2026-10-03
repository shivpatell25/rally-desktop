#!/bin/bash
# Assemble a locally signed development app and disk image.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.7.1}"
OUT="${OUT_DIR:-dist-native}"
swift build -c release
python3 packaging/assemble.py --configuration release --version "$VERSION" --output "$OUT/Rally.app"
hdiutil create -volname "Rally $VERSION" -srcfolder "$OUT/Rally.app" -ov -format UDZO "$OUT/Rally-$VERSION-macOS-development.dmg" >/dev/null
printf 'App: %s/Rally.app\nDisk image: %s/Rally-%s-macOS-development.dmg\n' "$OUT" "$OUT" "$VERSION"
