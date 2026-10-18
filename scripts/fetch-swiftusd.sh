#!/bin/sh
#
# fetch-swiftusd.sh: puts apple/SwiftUsd in Vendor/SwiftUsd, patched for Margolaria.
#
# Run it once after cloning the repository, and again after changing
# SWIFTUSD_TAG below. Packages/MargolariaKit depends on Vendor/SwiftUsd by
# path, so nothing builds until this has run.
#
# Why not depend on github.com/apple/SwiftUsd directly: its only library
# product, `OpenUSD`, includes SwiftUsd's Swift overlay (about 27,000 lines of
# generated Swift plus a macro that pulls in swift-syntax). We never
# `import OpenUSD`; our C++ and Objective-C++ bridges use only the headers
# and the prebuilt frameworks. Compiling the overlay took about 12 of the 13
# minutes of a clean build. The patch adds a second product, `OpenUSDCxx`,
# that contains just the headers and frameworks.
#
# Usage:
#   scripts/fetch-swiftusd.sh
#   SWIFTUSD_URL=/path/to/a/SwiftUsd/clone scripts/fetch-swiftusd.sh   # clone from a local copy

set -eu

# The SwiftUsd release we build against. OpenUSD and MaterialX versions follow
# from it (8.1.0: OpenUSD v26.08, MaterialX 1.39.5).
SWIFTUSD_TAG=8.1.0
SWIFTUSD_URL=${SWIFTUSD_URL:-https://github.com/apple/SwiftUsd.git}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/Vendor/SwiftUsd"
PATCH="$ROOT/Vendor/swiftusd-openusdcxx-product.patch"

if [ -d "$DEST/.git" ]; then
    CURRENT=$(git -C "$DEST" describe --tags --exact-match 2>/dev/null || echo unknown)
    if [ "$CURRENT" = "$SWIFTUSD_TAG" ] && git -C "$DEST" apply --reverse --check "$PATCH" 2>/dev/null; then
        echo "Vendor/SwiftUsd is already $SWIFTUSD_TAG with the patch applied."
        exit 0
    fi
    echo "Vendor/SwiftUsd is at $CURRENT; replacing it with $SWIFTUSD_TAG."
    rm -rf "$DEST"
fi

# A shallow clone of one tag: the xcframeworks are about 1.3 GB, and we
# don't need SwiftUsd's history.
echo "Cloning SwiftUsd $SWIFTUSD_TAG from $SWIFTUSD_URL ..."
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$SWIFTUSD_TAG" "$SWIFTUSD_URL" "$DEST"

git -C "$DEST" apply "$PATCH"
echo "Done: Vendor/SwiftUsd is SwiftUsd $SWIFTUSD_TAG with the OpenUSDCxx product."
