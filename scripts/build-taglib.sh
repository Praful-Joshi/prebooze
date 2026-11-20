#!/bin/zsh
# Build TagLib from its pinned source release for the app's minimum macOS.
#   scripts/build-taglib.sh   -> Vendor/taglib (then PREGAME_TAGLIB_PREFIX=Vendor/taglib)
#
# The app bundles libtag as a dylib (LGPL), and dyld won't load one built for a
# newer macOS than the one it runs on. Homebrew's libtag is built for the macOS
# of the machine that installed it, so releases build their own (docs/releasing.md).
# Day-to-day builds keep using Homebrew's.
set -euo pipefail
cd "${0:A:h:h}"

TAGLIB_VERSION="2.3.2"
TAGLIB_SHA256="3ca2d8afaa7f1cf7f6ed10e511ebc368bfacd6dcaa3dbfa690b89e502e8963dc"
# The same tarball Homebrew uses; it includes utfcpp, TagLib's only dependency besides zlib.
TAGLIB_URL="https://github.com/taglib/taglib/releases/download/v$TAGLIB_VERSION/taglib-$TAGLIB_VERSION.tar.gz"
MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' scripts/Info.plist)"
PREFIX="$PWD/Vendor/taglib"
LIB="$PREFIX/lib/libtag.2.dylib"

if [[ -f "$PREFIX/VERSION" && "$(<"$PREFIX/VERSION")" == "$TAGLIB_VERSION $MINIMUM" && -f "$LIB" ]]; then
  echo "TagLib $TAGLIB_VERSION for macOS $MINIMUM already built: $LIB"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Downloading TagLib $TAGLIB_VERSION"
curl --fail --silent --show-error --location --retry 3 -o "$tmp/taglib.tar.gz" "$TAGLIB_URL"
[[ "$(shasum -a 256 "$tmp/taglib.tar.gz" | cut -d' ' -f1)" == "$TAGLIB_SHA256" ]] \
  || { echo "TagLib source checksum mismatch" >&2; exit 1; }
tar -xzf "$tmp/taglib.tar.gz" -C "$tmp"

rm -rf "$PREFIX"
# The install name stays absolute, like Homebrew's; build-app.sh rewrites it
# to @rpath when it bundles the library.
cmake -S "$tmp/taglib-$TAGLIB_VERSION" -B "$tmp/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINIMUM" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUILD_SHARED_LIBS=ON \
  -DWITH_MP4=ON -DWITH_ASF=ON \
  -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF -DBUILD_BINDINGS=OFF \
  > "$tmp/configure.log" || { cat "$tmp/configure.log" >&2; exit 1; }
cmake --build "$tmp/build" --parallel "$(sysctl -n hw.ncpu)" > "$tmp/build.log" || { cat "$tmp/build.log" >&2; exit 1; }
cmake --install "$tmp/build" > /dev/null
echo "$TAGLIB_VERSION $MINIMUM" > "$PREFIX/VERSION"
echo "Built TagLib $TAGLIB_VERSION for macOS $MINIMUM: $LIB"
