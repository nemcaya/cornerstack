#!/bin/bash
# Builds Cornerstack.app and packs it into a disk image for releases.
# Needs uv (https://docs.astral.sh/uv/) to run dmgbuild, which writes the
# window layout itself instead of scripting Finder, so the image carries no
# paths or volume names from the Mac that built it.
# Usage: scripts/make-dmg.sh
#   ALLOW_DIRTY=1  build from a working tree with uncommitted changes
#   REBUILD=1      build a version again that already has an image
set -euo pipefail
cd "$(dirname "$0")/.."
# Dates inside the image are stored in UTC, not the build machine's time zone.
export TZ=UTC

# A release is what is committed, with every text in place.
if [ -z "${ALLOW_DIRTY:-}" ] && [ -n "$(git status --porcelain)" ]; then
  echo "There are uncommitted changes. Commit them first, or set ALLOW_DIRTY=1 to try the script out." >&2
  exit 1
fi
swift scripts/check-strings.swift

scripts/build-app.sh release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Cornerstack.app/Contents/Info.plist)"
DMG="build/Cornerstack-$VERSION.dmg"
TAP_DIR="${TAP_DIR:-$HOME/Code/homebrew-tap}"
CASK="$TAP_DIR/Casks/cornerstack.rb"

# No two images are the same, byte for byte, even from the same app. Once a
# version has its image, in the cask or as a tag, another one would give the
# cask a checksum that the published download does not have.
if [ -z "${REBUILD:-}" ]; then
  if [ -f "$CASK" ] && grep -q "^  version \"$VERSION\"" "$CASK"; then
    echo "The cask is already at $VERSION. Set REBUILD=1 to build its image again." >&2
    exit 1
  fi
  if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "v$VERSION is tagged already. Set REBUILD=1 to build its image again." >&2
    exit 1
  fi
fi

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

# The image must not carry paths from this Mac either, in its window layout
# for example. It is compressed, so it is unpacked to look inside.
RAW="$(mktemp -d)"
hdiutil convert "$DMG" -format UDTO -o "$RAW/image" -quiet
FOUND=0
LC_ALL=C grep -aqE '/Users/|/var/folders/' "$RAW/image.cdr" || FOUND=$?
rm -rf "$RAW"
if [ "$FOUND" -ne 1 ]; then
  echo "The disk image contains local paths (or could not be checked), not releasing it." >&2
  rm -f "$DMG"
  exit 1
fi
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

# Keep the Homebrew cask in step: new version and the checksum of this image.
# Set TAP_DIR to the checkout of github.com/nemcaya/homebrew-tap. Nothing is
# committed or pushed here, so the cask never points at a release that is not
# on GitHub yet. (The same step as in Tendedero's script.)
if [ -f "$CASK" ]; then
  SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
  # sed says nothing when a line it expects is not there.
  if ! grep -q "^  version \"$VERSION\"" "$CASK" || ! grep -q "^  sha256 \"$SHA\"" "$CASK"; then
    echo "Could not update $CASK: its version or sha256 line has changed shape." >&2
    exit 1
  fi
  echo "Updated $CASK to $VERSION ($SHA)"
  echo "After publishing the release: commit and push the tap."
else
  echo "No Homebrew cask at $CASK, skipped."
fi
