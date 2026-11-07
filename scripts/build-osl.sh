#!/bin/sh
#
# build-osl.sh: builds OpenShadingLanguage's command-line tools into
# Vendor/OSL: oslc (compiles .osl to .oso), testshade and testrender.
#
# Run it once after cloning the repository, and again after changing OSL_TAG
# below. A first build takes several minutes; a second run with the same tag
# does nothing.
#
# What they're for (PLAN.md §8.6, M5d): oslc compiles MaterialX's OSL
# library into the .oso files the network form of an exported shader needs
# (scripts/build-materialx-genosl.sh), and the tests compile every
# example's generated OSL with it. They are development tools, not part of
# the app: the app compiles exported shaders with whichever oslc is set in
# Settings, and still exports the .osl without one.
#
# Why build it: Homebrew has no OSL formula, and there is no prebuilt macOS
# arm64 release. OSL's own dependencies come from Homebrew, so these tools
# only run on a Mac with them installed:
#
#   brew install cmake ninja llvm openimageio imath pugixml bison flex
#
# (macOS's own bison is too old for OSL.)
#
# Usage:
#   scripts/build-osl.sh
#   OSL_URL=/path/to/an/OpenShadingLanguage/clone scripts/build-osl.sh   # clone from a local copy

set -eu

# The OSL release we build: the latest at the time of M5d (2026-11-07). It
# supports Homebrew's LLVM 23 and OpenImageIO 3.2.
OSL_TAG=v1.15.8.0
OSL_URL=${OSL_URL:-https://github.com/AcademySoftwareFoundation/OpenShadingLanguage.git}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENDOR="$ROOT/Vendor/OSL"
SOURCE="$VENDOR/source"
BUILD="$VENDOR/build"
INSTALL="$VENDOR/install"
STAMP="$VENDOR/built-tag"

if [ -x "$INSTALL/bin/oslc" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$OSL_TAG" ]; then
    echo "Vendor/OSL is already OSL $OSL_TAG."
    exit 0
fi

for tool in cmake ninja git brew; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "build-osl.sh needs $tool." >&2
        exit 1
    fi
done
for formula in llvm openimageio imath pugixml bison flex; do
    if ! brew list --versions "$formula" >/dev/null 2>&1; then
        echo "build-osl.sh needs Homebrew's $formula (brew install $formula)." >&2
        exit 1
    fi
done

rm -rf "$VENDOR"
mkdir -p "$VENDOR"

# A shallow clone of one tag; we don't need OSL's history.
echo "Cloning OSL $OSL_TAG from $OSL_URL ..."
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$OSL_TAG" "$OSL_URL" "$SOURCE"

# The tools and the libraries they need, nothing else: no Python bindings,
# no osltoy (Qt), no docs, no GPU (OptiX). OSL_BUILD_TESTS builds
# testshade and testrender, which load shaders and shader groups; its unit
# tests are built but not run.
echo "Building (this takes several minutes) ..."
cmake -S "$SOURCE" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DLLVM_ROOT="$(brew --prefix llvm)" \
    -DBISON_EXECUTABLE="$(brew --prefix bison)/bin/bison" \
    -DFLEX_EXECUTABLE="$(brew --prefix flex)/bin/flex" \
    -DFLEX_INCLUDE_DIR="$(brew --prefix flex)/include" \
    -DUSE_PYTHON=OFF \
    -DUSE_QT=OFF \
    -DUSE_PARTIO=OFF \
    -DOSL_USE_OPTIX=OFF \
    -DINSTALL_DOCS=OFF \
    -DOSL_BUILD_TESTS=ON \
    > "$VENDOR/cmake.log"
cmake --build "$BUILD" > "$VENDOR/build.log"
cmake --install "$BUILD" > "$VENDOR/install.log"

# A quick check that oslc runs and finds its standard header (stdosl.h).
printf 'shader check(output float out = 1) { }\n' > "$VENDOR/check.osl"
"$INSTALL/bin/oslc" -q -o "$VENDOR/check.oso" "$VENDOR/check.osl"
rm "$VENDOR/check.osl" "$VENDOR/check.oso"

# The build folder is a few GB; only the installed tools are needed.
rm -rf "$BUILD"
echo "$OSL_TAG" > "$STAMP"
echo "Done: Vendor/OSL/install/bin/oslc is OSL $OSL_TAG."
