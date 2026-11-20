#!/bin/zsh
# Check that code runs on the app's minimum macOS (LSMinimumSystemVersion in
# scripts/Info.plist): every Mach-O in an app or folder, and every object in a
# static library linked into it.
#   scripts/check-min-macos.sh build/Pregame.app /opt/homebrew/lib/libmpg123.a
#   scripts/check-min-macos.sh --minimum 15.0 build/Pregame.app
#
# The linker only warns when it links code built for a newer macOS, and dyld
# refuses to load a bundled library built that way. Homebrew builds its
# libraries for the macOS it runs on, so this catches a release built from the
# wrong machine's libraries (docs/releasing.md).
set -euo pipefail

MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${0:A:h}/Info.plist")"
if [[ "${1:-}" == --minimum && $# -ge 2 ]]; then
  MINIMUM="$2"
  shift 2
fi
if [[ $# == 0 || "$1" == -* ]]; then
  echo "usage: scripts/check-min-macos.sh [--minimum <macOS>] <app, folder or library>..." >&2
  exit 2
fi

# True if version $1 is newer than version $2 (missing parts count as 0).
newer() {
  local -a a b
  a=("${(@s:.:)1}") b=("${(@s:.:)2}")
  for i in 1 2 3; do
    (( ${a[i]:-0} > ${b[i]:-0} )) && return 0
    (( ${a[i]:-0} < ${b[i]:-0} )) && return 1
  done
  return 1
}

checked=0
failed=0
check() {
  local file="$1" name="$2" kind
  kind="$(file -b "$file")"
  [[ "$kind" == Mach-O* || "$kind" == *"ar archive"* ]] || return 0
  checked=$((checked + 1))
  # Each architecture (or archive member) records one minimum: LC_BUILD_VERSION's
  # minos, or the older LC_VERSION_MIN_MACOSX's version. Print "member minimum".
  local -a minimums
  minimums=("${(@f)$(otool -l "$file" 2>/dev/null | awk '
    /^Archive : / { next }
    /\):$/ && /\(/ { sub(/:$/, ""); n = split($0, parts, "("); member = "(" parts[n]; next }
    $1 == "cmd" { cmd = $2 }
    cmd == "LC_BUILD_VERSION" && $1 == "minos" { print member " " $2 }
    cmd == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print member " " $2 }')}")
  minimums=(${minimums:#})
  if (( ${#minimums} == 0 )); then
    echo "$name: no minimum macOS recorded" >&2
    failed=$((failed + 1))
    return 0
  fi
  local line minimum
  for line in "${minimums[@]}"; do
    minimum="${line##* }"
    if newer "$minimum" "$MINIMUM"; then
      echo "$name${line% *}: needs macOS $minimum, newer than $MINIMUM" >&2
      failed=$((failed + 1))
      return 0
    fi
  done
}

for target in "$@"; do
  if [[ -d "$target" ]]; then
    while IFS= read -r -d '' file; do
      check "$file" "${file#${target%/}/}"
    done < <(find "$target" -type f -print0)
  elif [[ -f "$target" ]]; then
    check "$target" "${target:t}"
  else
    echo "error: $target doesn't exist" >&2
    exit 1
  fi
done

if (( checked == 0 )); then
  echo "error: no code found in $*" >&2
  exit 1
fi
if (( failed > 0 )); then
  echo "error: $failed of $checked files hold code that won't run on macOS $MINIMUM" >&2
  exit 1
fi
echo "All $checked files of code run on macOS $MINIMUM"
