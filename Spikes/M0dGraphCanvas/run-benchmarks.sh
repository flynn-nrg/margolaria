#!/bin/sh
#
# run-benchmarks.sh: runs the M0d canvas benchmark for both renderers at 500
# and 2,000 nodes and prints the results.
#
# The screen must be unlocked and awake, and the window visible: macOS stops
# display links otherwise, and the benchmark stops with "No frames".
# `caffeinate -d` keeps the display awake while it runs. Don't touch the
# mouse or keyboard during a run (about 25 seconds each).
#
# Usage, from the repository root, after building the Release app:
#   xcodebuild -scheme GraphSpike -configuration Release -skipMacroValidation -derivedDataPath build/DerivedData build
#   Spikes/M0dGraphCanvas/run-benchmarks.sh [output-folder]

set -eu

APP=build/DerivedData/Build/Products/Release/GraphSpike.app
OUT=${1:-build/benchmarks}
mkdir -p "$OUT"

for nodes in 500 2000; do
    for renderer in layers canvas; do
        file="$OUT/${renderer}_${nodes}.txt"
        rm -f "$file"
        caffeinate -d open -W -n "$APP" --args -renderer "$renderer" -nodes "$nodes" -out "$PWD/$file"
        cat "$file"
        echo
    done
done
