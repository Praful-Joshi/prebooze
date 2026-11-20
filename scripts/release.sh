#!/bin/zsh
# Build, check and package a release (docs/releasing.md).
#   scripts/release.sh v0.2   -> build/release/Pregame-0.2.dmg
#
# The tag must be v<CFBundleShortVersionString> from scripts/Info.plist. The
# app is built against TagLib from pinned source and the checksum-verified ONNX
# Runtime and Demucs model, signed by build-app.sh (so the signing identity
# must be in a keychain), and checked to load on the minimum macOS. The
# release workflow then signs the appcast and publishes both; this script
# never touches the update key.
set -euo pipefail
cd "${0:A:h:h}"

if [[ $# != 1 ]]; then
  echo "usage: scripts/release.sh v<version>" >&2
  exit 2
fi
TAG="$1"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" scripts/Info.plist; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"

# Check everything about the version before spending minutes building.
if [[ "$TAG" != "v$VERSION" ]]; then
  echo "error: the tag $TAG doesn't match CFBundleShortVersionString $VERSION in scripts/Info.plist." >&2
  echo "Raise the version there first, then tag that commit v<version> (docs/releasing.md)." >&2
  exit 1
fi
if [[ ! "$VERSION" =~ '^[0-9]+(\.[0-9]+){1,2}$' || ! "$BUILD" =~ '^[0-9]+$' ]]; then
  echo "error: CFBundleShortVersionString ($VERSION) must look like 1.2 or 1.2.3, and CFBundleVersion ($BUILD) must be a whole number." >&2
  exit 1
fi

# The static libraries Package.swift links from Homebrew must already be built
# for the minimum macOS: Homebrew builds for the macOS it runs on, so a release
# builds on the minimum macOS. TagLib, the one bundled dylib, is built here.
scripts/check-min-macos.sh /opt/homebrew/lib/{librubberband,libsamplerate,libmp3lame,libmpg123}.a

scripts/build-taglib.sh
scripts/fetch-vendor.sh --model
PREGAME_TAGLIB_PREFIX=Vendor/taglib scripts/build-app.sh
APP=build/Pregame.app
scripts/check-min-macos.sh "$APP"

# The DMG holds the app and a link to /Applications to drag it onto.
OUT=build/release
DMG="$OUT/Pregame-$VERSION.dmg"
rm -rf "$OUT"
mkdir -p "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Pregame/Pregame.app"
ln -s /Applications "$STAGE/Pregame/Applications"
hdiutil create -quiet -volname Pregame -srcfolder "$STAGE/Pregame" -fs HFS+ -format UDZO "$DMG"
hdiutil verify -quiet "$DMG"
echo "Packaged $DMG (Pregame $VERSION, build $BUILD)"
