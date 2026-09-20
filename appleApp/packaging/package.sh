#!/bin/bash
# Builds an unsigned RallyDesktop.app + DMG from the SwiftPM release binary.
# Signing/notarization (Team ID) slots in later; layout already matches a
# signed bundle so nothing moves.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
OUT="${OUT_DIR:-./dist}"
APP="$OUT/RallyDesktop.app"
CONTENTS="$APP/Contents"

echo "==> swift build -c release"
swift build -c release

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$CONTENTS/Resources"

cp .build/release/RallyDesktop "$CONTENTS/MacOS/RallyDesktop"
for FW in VLCKit Sparkle; do
    rm -rf "$CONTENTS/Frameworks/$FW.framework"
    cp -R ".build/release/$FW.framework" "$CONTENTS/Frameworks/"
    # Strip debug symbols and helper tooling SPM stages but the app never loads.
    rm -rf "$CONTENTS/Frameworks/$FW.framework.dSYM"
done
rm -rf "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/XPCServices/"*.dSYM 2>/dev/null || true

# Icon from the brand kit (1024 master -> .icns).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
SRC="../Rally_Brand_Kit/05_App_Icons/rally_app_icon_1024x1024.png"
for S in 16 32 128 256 512; do
    D="$ICONSET/icon_${S}x${S}.png"
    /usr/bin/sips -z $S $S "$SRC" --out "$D" >/dev/null
    /usr/bin/sips -z $((S*2)) $((S*2)) "$SRC" --out "${ICONSET}/icon_${S}x${S}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

# Info.plist with version + staged Sparkle public key.
PUBKEY="$(cat sparkle_public_key.txt)"
sed -e "s/__VERSION__/$VERSION/" -e "s#__SPARKLE_PUBLIC_KEY__#$PUBKEY#" \
    packaging/Info.plist > "$CONTENTS/Info.plist"

# Resolve @rpath against the embedded Frameworks (unsigned build).
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/RallyDesktop" 2>/dev/null || true

echo "==> verifying linkage"
otool -L "$CONTENTS/MacOS/RallyDesktop" | grep -E "VLCKit|Sparkle"
test -f "$CONTENTS/Frameworks/VLCKit.framework/Versions/A/VLCKit"
test -f "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/Sparkle"
/usr/bin/plutil -lint "$CONTENTS/Info.plist"

echo "==> DMG"
DMG="$OUT/Rally-$VERSION-macOS-unsigned.dmg"
rm -f "$DMG"
hdiutil create -volname "Rally $VERSION" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
echo "DONE: $APP"
echo "DONE: $DMG"
