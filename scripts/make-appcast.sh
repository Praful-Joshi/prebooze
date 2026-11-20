#!/bin/zsh
# Generate the signed Sparkle appcast for one release DMG (docs/updates.md).
#   scripts/make-appcast.sh build/Pregame-0.2.dmg            -> build/appcast/appcast.xml
#   scripts/make-appcast.sh build/Pregame-0.2.dmg <out-dir>  -> <out-dir>/appcast.xml
#
# The appcast has one item: the DMG as an asset of the GitHub Release tagged
# v<CFBundleShortVersionString>. Upload both files to that release; the app
# reads releases/latest/download/appcast.xml.
#
# Release notes: put Pregame-0.2.md (or .html) next to the DMG to embed them.
# Signing key: the update key in your login keychain, or set
# PREGAME_SPARKLE_KEY_FILE to a file holding it (`-` reads it from stdin).
# The key must be the one installed copies trust: the app's SUPublicEDKey, or
# for the one bridge release that rotates the key, PREGAME_INSTALLED_PUBLIC_KEY
# (docs/releasing.md).
set -euo pipefail
ROOT="${0:A:h:h}"
REPOSITORY="https://github.com/Praful-Joshi/pregame"

if [[ $# -lt 1 || $# -gt 2 || "$1" != *.dmg || ! -f "$1" ]]; then
  echo "usage: scripts/make-appcast.sh <Pregame-x.y.dmg> [out-dir]" >&2
  exit 2
fi
DMG="${1:A}"
OUT="${${2:-$ROOT/build/appcast}:A}"

# Sparkle's tools come with the Swift package (Package.swift pins the version).
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$TOOLS/generate_appcast" ]]; then
  (cd "$ROOT" && swift package resolve)
fi

WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
cleanup() {
  [[ -d "$MOUNT" ]] && hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# The release tag comes from the version of the app inside the DMG.
mkdir "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG"
APPS=("$MOUNT"/*.app(N))
if [[ ${#APPS} != 1 ]]; then
  echo "error: expected one app in $DMG, found ${#APPS}" >&2
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APPS[1]/Contents/Info.plist")"
APP_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APPS[1]/Contents/Info.plist")"
TRUSTED_KEY="${PREGAME_INSTALLED_PUBLIC_KEY:-$APP_KEY}"
hdiutil detach -quiet "$MOUNT"
rmdir "$MOUNT"

# generate_appcast reads every archive in a folder, so give it only this one.
STAGE="$WORK/stage"
mkdir "$STAGE"
cp "$DMG" "$STAGE/"
NOTES=("${DMG:r}".{md,html}(N))
(( ${#NOTES} )) && cp "$NOTES[1]" "$STAGE/"

# Run a Sparkle tool with the update key. A key on stdin is read once and piped
# to each tool, so it never touches the disk.
KEY_FILE="${PREGAME_SPARKLE_KEY_FILE:-}"
KEY_TEXT=""
if [[ "$KEY_FILE" == - ]]; then
  KEY_TEXT="$(cat)"
  [[ -n "$KEY_TEXT" ]] || { echo "error: no update key on standard input." >&2; exit 1; }
fi
with_key() {
  case "$KEY_FILE" in
    "") "$@" ;;
    -) printf '%s' "$KEY_TEXT" | "$@" --ed-key-file - ;;
    *) "$@" --ed-key-file "$KEY_FILE" ;;
  esac
}

with_key "$TOOLS/generate_appcast" \
  --download-url-prefix "$REPOSITORY/releases/download/v$VERSION/" \
  --embed-release-notes \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  -o "$WORK/appcast.xml" \
  "$STAGE"

SIGNATURE="$(xmllint --xpath 'string(//item/enclosure/@*[local-name()="edSignature"])' "$WORK/appcast.xml")"
# generate_appcast leaves the DMG unsigned when the key isn't the app's own,
# which is the point of a bridge release: sign it, then sign the feed again.
if [[ -z "$SIGNATURE" && "$TRUSTED_KEY" != "$APP_KEY" ]]; then
  SIGNATURE="$(with_key "$TOOLS/sign_update" -p "$DMG")"
  sed -i '' "s|<enclosure url=|<enclosure sparkle:edSignature=\"$SIGNATURE\" url=|" "$WORK/appcast.xml"
  with_key "$TOOLS/sign_update" "$WORK/appcast.xml"
fi

# Installed copies accept only an update signed with the key they trust. With
# any other key generate_appcast only warns, so check the signature before
# writing anything.
if [[ -z "$SIGNATURE" ]] || ! swift "$ROOT/scripts/verify-update-signature.swift" "$DMG" "$SIGNATURE" "$TRUSTED_KEY"; then
  echo "error: the update key doesn't match $TRUSTED_KEY, the key installed copies trust (SUPublicEDKey, or PREGAME_INSTALLED_PUBLIC_KEY for a bridge release), so they would reject this update." >&2
  echo "Sign with the key whose public half that is (docs/releasing.md); never change SUPublicEDKey to fit a new key." >&2
  exit 1
fi
mkdir -p "$OUT"
mv "$WORK/appcast.xml" "$OUT/appcast.xml"
echo "Wrote $OUT/appcast.xml for Pregame $VERSION; upload it and ${DMG:t} to the v$VERSION release."
