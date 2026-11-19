#!/bin/zsh
# Fetch the vendored binaries that are too big to commit, and verify their checksums.
#   scripts/fetch-vendor.sh   -> Vendor/onnxruntime/lib/libonnxruntime.1.dylib
#
# ONNX Runtime 1.31.0 (MIT) comes from Microsoft's official NuGet package. Its
# macOS arm64 library is the same build as the one in the GitHub release
# (only the code-signature block differs) and is signed by Microsoft.
#
# The Demucs model (Models/htdemucs.onnx.data) is not fetched here: only stem
# separation needs it, and no default test does that. See scripts/stems/README.md.
set -euo pipefail
cd "${0:A:h:h}"

ORT_VERSION="1.31.0"
ORT_NUPKG_SHA256="7e35fdb4f5adb62f01e60798e2e5ed05108f5fbbe1cca03fbcc37903cf7c5e3b"
ORT_DYLIB_SHA256="83973572676032b4ba9418afed0b51f45599d35bb4e4628ca8ae1954c8362e31"
ORT_DYLIB="Vendor/onnxruntime/lib/libonnxruntime.1.dylib"
# The same library from the GitHub release tarball (renamed), which older clones have.
ORT_DYLIB_RELEASE_SHA256="2a50a63e7f41f8d4d551d3ee47248df3864f6540109fce8ad520ca3b51af4b70"

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [[ -f "$ORT_DYLIB" ]]; then
  case "$(sha256 "$ORT_DYLIB")" in
    "$ORT_DYLIB_SHA256"|"$ORT_DYLIB_RELEASE_SHA256") echo "ONNX Runtime present and verified: $ORT_DYLIB"; exit 0 ;;
    *) echo "$ORT_DYLIB doesn't match ONNX Runtime $ORT_VERSION; delete it and run again" >&2; exit 1 ;;
  esac
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
url="https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/$ORT_VERSION/microsoft.ml.onnxruntime.$ORT_VERSION.nupkg"
echo "Downloading ONNX Runtime $ORT_VERSION"
curl --fail --silent --show-error --location --retry 3 -o "$tmp/ort.nupkg" "$url"
[[ "$(sha256 "$tmp/ort.nupkg")" == "$ORT_NUPKG_SHA256" ]] || { echo "ONNX Runtime package checksum mismatch" >&2; exit 1; }
unzip -q -o "$tmp/ort.nupkg" "runtimes/osx-arm64/native/libonnxruntime.dylib" -d "$tmp"
[[ "$(sha256 "$tmp/runtimes/osx-arm64/native/libonnxruntime.dylib")" == "$ORT_DYLIB_SHA256" ]] \
  || { echo "ONNX Runtime library checksum mismatch" >&2; exit 1; }
mkdir -p "${ORT_DYLIB:h}"
mv "$tmp/runtimes/osx-arm64/native/libonnxruntime.dylib" "$ORT_DYLIB"
echo "Installed $ORT_DYLIB"
