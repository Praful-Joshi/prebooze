#!/bin/zsh
# Fetch the vendored binaries that are too big to commit, and verify their checksums.
#   scripts/fetch-vendor.sh           -> Vendor/onnxruntime/lib/libonnxruntime.1.dylib
#   scripts/fetch-vendor.sh --model   -> also Models/htdemucs.onnx.data (releases need it)
#
# ONNX Runtime 1.31.0 (MIT) comes from Microsoft's official NuGet package. Its
# macOS arm64 library is the same build as the one in the GitHub release
# (only the code-signature block differs) and is signed by Microsoft.
#
# The Demucs model (MIT) is our ONNX export of htdemucs (scripts/stems/README.md):
# the graph, Models/htdemucs.onnx, is committed; its weights are too big for git
# and are an asset of the GitHub Release tagged model-htdemucs-1. Only stem
# separation needs them, and no default test does that, so they're fetched only
# with --model. Files already present are verified, never trusted.
set -euo pipefail
cd "${0:A:h:h}"

case "${1:-}" in
  "") MODEL=0 ;;
  --model) MODEL=1 ;;
  *) echo "usage: scripts/fetch-vendor.sh [--model]" >&2; exit 2 ;;
esac

ORT_VERSION="1.31.0"
ORT_NUPKG_SHA256="7e35fdb4f5adb62f01e60798e2e5ed05108f5fbbe1cca03fbcc37903cf7c5e3b"
ORT_DYLIB_SHA256="83973572676032b4ba9418afed0b51f45599d35bb4e4628ca8ae1954c8362e31"
ORT_DYLIB="Vendor/onnxruntime/lib/libonnxruntime.1.dylib"
# The same library from the GitHub release tarball (renamed), which older clones have.
ORT_DYLIB_RELEASE_SHA256="2a50a63e7f41f8d4d551d3ee47248df3864f6540109fce8ad520ca3b51af4b70"

MODELS="${PREGAME_MODELS_DIR:-Models}"
MODEL_URL="https://github.com/Praful-Joshi/pregame/releases/download/model-htdemucs-1/htdemucs.onnx.data"
MODEL_GRAPH_SHA256="d987979f5a3619c6c81505fb24d9357dd90b208689ea4ce4278cc483a4515aae"
MODEL_WEIGHTS_SHA256="a54c528be24273dc291b8514883dc64b1159251d5132d8c0e9a2cf3ca4bdf730"

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
download() { curl --fail --silent --show-error --location --retry 3 -o "$2" "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ -f "$ORT_DYLIB" ]]; then
  case "$(sha256 "$ORT_DYLIB")" in
    "$ORT_DYLIB_SHA256"|"$ORT_DYLIB_RELEASE_SHA256") echo "ONNX Runtime present and verified: $ORT_DYLIB" ;;
    *) echo "$ORT_DYLIB doesn't match ONNX Runtime $ORT_VERSION; delete it and run again" >&2; exit 1 ;;
  esac
else
  echo "Downloading ONNX Runtime $ORT_VERSION"
  download "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/$ORT_VERSION/microsoft.ml.onnxruntime.$ORT_VERSION.nupkg" "$tmp/ort.nupkg"
  [[ "$(sha256 "$tmp/ort.nupkg")" == "$ORT_NUPKG_SHA256" ]] || { echo "ONNX Runtime package checksum mismatch" >&2; exit 1; }
  unzip -q -o "$tmp/ort.nupkg" "runtimes/osx-arm64/native/libonnxruntime.dylib" -d "$tmp"
  [[ "$(sha256 "$tmp/runtimes/osx-arm64/native/libonnxruntime.dylib")" == "$ORT_DYLIB_SHA256" ]] \
    || { echo "ONNX Runtime library checksum mismatch" >&2; exit 1; }
  mkdir -p "${ORT_DYLIB:h}"
  mv "$tmp/runtimes/osx-arm64/native/libonnxruntime.dylib" "$ORT_DYLIB"
  echo "Installed $ORT_DYLIB"
fi

(( MODEL )) || exit 0

[[ -f "$MODELS/htdemucs.onnx" ]] || { echo "$MODELS/htdemucs.onnx is missing (it's in the repository)" >&2; exit 1; }
[[ "$(sha256 "$MODELS/htdemucs.onnx")" == "$MODEL_GRAPH_SHA256" ]] \
  || { echo "$MODELS/htdemucs.onnx doesn't match the pinned Demucs model" >&2; exit 1; }
WEIGHTS="$MODELS/htdemucs.onnx.data"
if [[ -f "$WEIGHTS" ]]; then
  [[ "$(sha256 "$WEIGHTS")" == "$MODEL_WEIGHTS_SHA256" ]] \
    || { echo "$WEIGHTS doesn't match the pinned Demucs model; delete it and run again" >&2; exit 1; }
  echo "Demucs model present and verified: $WEIGHTS"
else
  echo "Downloading the Demucs model weights"
  download "$MODEL_URL" "$tmp/htdemucs.onnx.data"
  [[ "$(sha256 "$tmp/htdemucs.onnx.data")" == "$MODEL_WEIGHTS_SHA256" ]] \
    || { echo "the downloaded Demucs weights don't match the pinned checksum" >&2; exit 1; }
  mv "$tmp/htdemucs.onnx.data" "$WEIGHTS"
  echo "Installed $WEIGHTS"
fi
