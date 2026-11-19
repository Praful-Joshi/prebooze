#!/bin/zsh
# Build Pregame.app (release) and optionally install it into /Applications.
#   scripts/build-app.sh            -> build/Pregame.app
#   scripts/build-app.sh --install  -> also copy to /Applications
set -euo pipefail
cd "${0:A:h:h}"

swift build -c release --product Pregame
BIN="$(swift build -c release --show-bin-path)"
APP="build/Pregame.app"
TAGLIB="/opt/homebrew/opt/taglib/lib/libtag.2.dylib"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Pregame" "$APP/Contents/MacOS/Pregame"
cp -R "$BIN/Pregame_PregameCore.bundle" "$APP/Contents/Resources/"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # from scripts/icon/make-icon.swift
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp Vendor/onnxruntime/LICENSE "$APP/Contents/Resources/ONNXRUNTIME_LICENSE"
cp Sources/QMDSP/COPYING "$APP/Contents/Resources/QMDSP_COPYING"

# Bundle TagLib so the app doesn't depend on Homebrew at runtime.
cp "$TAGLIB" "$APP/Contents/Frameworks/libtag.2.dylib"
chmod u+w "$APP/Contents/Frameworks/libtag.2.dylib"
install_name_tool -id "@rpath/libtag.2.dylib" "$APP/Contents/Frameworks/libtag.2.dylib"
install_name_tool -change "$TAGLIB" "@rpath/libtag.2.dylib" "$APP/Contents/MacOS/Pregame"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Pregame"

# ONNX Runtime (stems) and the Demucs model (exported to ONNX, see README).
cp Vendor/onnxruntime/lib/libonnxruntime.1.dylib "$APP/Contents/Frameworks/libonnxruntime.1.dylib"
chmod u+w "$APP/Contents/Frameworks/libonnxruntime.1.dylib"
mkdir -p "$APP/Contents/Resources/Models"
cp Models/htdemucs.onnx Models/htdemucs.onnx.data "$APP/Contents/Resources/Models/"

codesign --force --sign - "$APP/Contents/Frameworks/libonnxruntime.1.dylib"
codesign --force --sign - "$APP/Contents/Frameworks/libtag.2.dylib"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Pregame.app
  cp -R "$APP" /Applications/Pregame.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Pregame.app
  echo "Installed /Applications/Pregame.app"
fi
