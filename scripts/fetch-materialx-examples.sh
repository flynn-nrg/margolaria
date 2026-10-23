#!/bin/sh
#
# fetch-materialx-examples.sh: puts MaterialX's example materials and their
# images in Vendor/MaterialX, for tests and for trying the app.
#
# M1's exit criterion is that Margolaria opens every example in MaterialX's
# resources/Materials/Examples (docs/PLAN.md §8). MXKit's corpus test opens
# them all; it is skipped, with a message, when this folder doesn't exist.
#
# Only two folders of the MaterialX repository are checked out (about 52 MB):
#   resources/Materials/Examples   50 .mtlx files, some with their own textures
#   resources/Images               textures that the examples refer to
# The data libraries (stdlib, pbrlib, ...) are not needed: they ship inside
# SwiftUsd's frameworks.
#
# Usage:
#   scripts/fetch-materialx-examples.sh

set -eu

# The MaterialX release bundled in SwiftUsd 8.1.0 (scripts/fetch-swiftusd.sh).
# Keep the two in step: examples from a newer MaterialX may use nodes our
# libraries don't define.
MATERIALX_TAG=v1.39.5
MATERIALX_URL=${MATERIALX_URL:-https://github.com/AcademySoftwareFoundation/MaterialX.git}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/Vendor/MaterialX"

if [ -d "$DEST/.git" ]; then
    CURRENT=$(git -C "$DEST" describe --tags --exact-match 2>/dev/null || echo unknown)
    if [ "$CURRENT" = "$MATERIALX_TAG" ]; then
        echo "Vendor/MaterialX is already $MATERIALX_TAG."
        exit 0
    fi
    echo "Vendor/MaterialX is at $CURRENT; replacing it with $MATERIALX_TAG."
    rm -rf "$DEST"
fi

# A shallow, sparse clone: `--filter=blob:none` downloads file contents only
# for the folders checked out below, and `--sparse` starts with none of them.
echo "Cloning MaterialX $MATERIALX_TAG examples from $MATERIALX_URL ..."
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$MATERIALX_TAG" \
    --filter=blob:none --sparse "$MATERIALX_URL" "$DEST"
git -C "$DEST" sparse-checkout set resources/Materials/Examples resources/Images

COUNT=$(find "$DEST/resources/Materials/Examples" -name '*.mtlx' | wc -l | tr -d ' ')
echo "Done: Vendor/MaterialX has $COUNT example documents from MaterialX $MATERIALX_TAG."
