#!/bin/zsh
# Run the real-music suites that stay out of the default `swift test`, in a
# release build. They need your own music, which is never committed.
#
#   scripts/test-real-music.sh <music folder> [export output folder]
#
# Always runs:
#   AnalysisParityTests  keys/BPMs vs what Mixxx stored (files in Fixtures/mixxx_analysis.json that exist here)
#   RealExportTests      exports <music folder> as one Mix and checks every join for clicks
#   RealStructureTests   prints detected song structure for <music folder>
# Also runs, when you set their variables:
#   PREGAME_STEM_REF=<dir>          StemTests.testMatchesReference (ref_in.npy, ref_out.npy)
#   PREGAME_STEM_PAIR="/a.mp3|/b.mp3"  RealStemMixTests (stems already cached)
#   PREGAME_STEM_FILE=<audio>       StemTiming
#   PREGAME_SHIFT_FILE=<audio>      RealKeyShiftTiming
set -euo pipefail
cd "${0:A:h:h}"

if [[ $# -lt 1 || ! -d "$1" ]]; then
  echo "usage: $0 <music folder> [export output folder]" >&2
  exit 2
fi
music="${1:A}"
out="${2:-$(mktemp -d)/real-export}"
mkdir -p "$out"
echo "Music: $music"
echo "Export output: $out"

PREGAME_PARITY=1 \
PREGAME_EXPORT="$music" \
PREGAME_EXPORT_OUT="${out:A}" \
PREGAME_STRUCTURE="$music" \
  swift test -c release \
    --filter 'AnalysisParityTests|RealExportTests|RealStructureTests|RealStemMixTests|RealKeyShiftTiming|StemTiming|StemTests.testMatchesReference'
