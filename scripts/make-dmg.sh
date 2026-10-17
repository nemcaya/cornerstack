#!/bin/bash
# Builds Cornerstack.app and packs it into a disk image for releases.
# Needs uv (https://docs.astral.sh/uv/) to run dmgbuild, which writes the
# window layout itself instead of scripting Finder, so the image carries no
# paths or volume names from the Mac that built it.
# Usage: scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# Dates inside the image are stored in UTC, not the build machine's time zone.
export TZ=UTC

scripts/build-app.sh release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Cornerstack.app/Contents/Info.plist)"
DMG="build/Cornerstack-$VERSION.dmg"

WORK="$(mktemp -d)"
swift scripts/make-dmg-background.swift "$WORK/bg1x.png" 1
swift scripts/make-dmg-background.swift "$WORK/bg2x.png" 2
# One TIFF holding both resolutions, so the window is sharp on Retina.
tiffutil -cathidpicheck "$WORK/bg1x.png" "$WORK/bg2x.png" -out "$WORK/background.tiff" >/dev/null

rm -f "$DMG"
uvx dmgbuild==1.6.7 -s scripts/dmg-settings.py \
  -D app=build/Cornerstack.app -D background="$WORK/background.tiff" \
  Cornerstack "$DMG"
rm -rf "$WORK"
echo "Built $DMG"

# Sign the disk image, send it to Apple for notarization and staple the
# ticket, so it opens without warnings even offline. Needs a Developer ID and
# notary credentials stored with:
#   xcrun notarytool store-credentials cornerstack-notary --apple-id ... --team-id ...
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
PROFILE="${NOTARY_PROFILE:-cornerstack-notary}"
if [ -n "$IDENTITY" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "Notarizing, this usually takes a few minutes..."
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  else
    echo "No notary credentials in profile $PROFILE: the image is signed but not notarized."
  fi
fi
