#!/bin/sh
#
# build-pymaterialx.sh: builds MaterialX's Python bindings (PyMaterialX) for
# Margolaria's embedded Python, as the `MaterialX` package in
# Vendor/PyMaterialX/site-packages.
#
# Run it once after cloning the repository, after fetch-swiftusd.sh and
# fetch-python.sh, and again after changing MATERIALX_TAG below or the
# Python build. A second run with the same tag and Python does nothing.
#
# Why build it: SwiftUsd is built without Python and ships no bindings
# (PLAN.md §8.7). MaterialX 1.39.5's PyMaterialX sources are compiled here
# against SwiftUsd's MaterialX headers and linked to its MaterialXCore and
# MaterialXFormat frameworks, so `import MaterialX` in a script uses the
# same MaterialX as the app, and can be handed the app's own documents
# (the C++ objects themselves, not copies).
#
# What it makes:
#   site-packages/MaterialX/   the package: MaterialX's own Python files and
#                              its two compiled modules, PyMaterialXCore and
#                              PyMaterialXFormat (arm64, for Python 3.13)
#   include/pybind11/          the pybind11 headers PyMaterialX was built
#                              with; Margolaria's bridge must use the same
#                              ones, so both see one set of Python types
#
# The modules don't link Python itself (`-undefined dynamic_lookup`, as for
# any extension module): they use the interpreter that loads them. They find
# MaterialX's frameworks through their rpath: the app's Contents/Frameworks
# from Contents/Resources/Python/site-packages/MaterialX. They are signed ad
# hoc here; Xcode's build signs them with our identity
# (scripts/embed-python.sh).
#
# Usage:
#   scripts/build-pymaterialx.sh
#   MATERIALX_URL=/path/to/a/MaterialX/clone scripts/build-pymaterialx.sh

set -eu

# The MaterialX release bundled in SwiftUsd 8.1.0 (scripts/fetch-swiftusd.sh).
# It must match exactly: the bindings use MaterialX's C++ classes directly.
MATERIALX_TAG=v1.39.5
MATERIALX_URL=${MATERIALX_URL:-https://github.com/AcademySoftwareFoundation/MaterialX.git}

# Must match Config/Base.xcconfig.
DEPLOYMENT_TARGET=15.0

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENDOR="$ROOT/Vendor/PyMaterialX"
SOURCE="$VENDOR/source"
BUILD="$VENDOR/build"
PACKAGE="$VENDOR/site-packages/MaterialX"
STAMP="$VENDOR/built-from"

# SwiftUsd's MaterialX: headers and frameworks.
SWIFTUSD="$ROOT/Vendor/SwiftUsd/swift-package"
HEADERS="$SWIFTUSD/Sources/_OpenUSD_SwiftBindingHelpers/include"
LIBRARIES="$SWIFTUSD/Libraries"

# fetch-python.sh's Python: its headers, and the version that names the
# modules (PyMaterialXCore.cpython-313-darwin.so).
PYTHON_FRAMEWORK="$ROOT/Vendor/Python/Python.xcframework/macos-arm64/Python.framework"
PYTHON_TAG=cpython-313-darwin

BUILT_FROM="$MATERIALX_TAG $(cat "$ROOT/Vendor/Python/built-from" 2>/dev/null)"

if [ -d "$PACKAGE" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$BUILT_FROM" ]; then
    echo "Vendor/PyMaterialX is already MaterialX $MATERIALX_TAG for Python $(cat "$ROOT/Vendor/Python/built-from")."
    exit 0
fi

if [ ! -d "$HEADERS/MaterialXCore" ]; then
    echo "Run scripts/fetch-swiftusd.sh first." >&2
    exit 1
fi
if [ ! -d "$PYTHON_FRAMEWORK" ]; then
    echo "Run scripts/fetch-python.sh first." >&2
    exit 1
fi

rm -rf "$VENDOR"
mkdir -p "$BUILD" "$PACKAGE" "$VENDOR/include"

# A shallow, sparse clone of the folders we need: the bindings' C++ (with
# the pybind11 they ship) and the package's Python files.
echo "Cloning MaterialX $MATERIALX_TAG's Python bindings from $MATERIALX_URL ..."
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$MATERIALX_TAG" \
    --filter=blob:none --sparse "$MATERIALX_URL" "$SOURCE"
git -C "$SOURCE" sparse-checkout set source/PyMaterialX python/MaterialX
PYBIND11="$SOURCE/source/PyMaterialX/External/PyBind11/include"

# The flags MaterialX's CMake uses for the bindings on macOS: C++17,
# symbols visible (pybind11 needs its types shared between modules).
CXXFLAGS="-std=c++17 -O2 -arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET
    -Wno-undefined-var-template
    -I$SOURCE/source -I$PYBIND11 -I$HEADERS -I$PYTHON_FRAMEWORK/Headers"
LDFLAGS="-bundle -undefined dynamic_lookup -arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET
    -Wl,-rpath,@loader_path/../../../../Frameworks
    -F$LIBRARIES/MaterialXCore.xcframework/macos-arm64
    -F$LIBRARIES/MaterialXFormat.xcframework/macos-arm64"

# build MODULE FRAMEWORKS: compiles source/PyMaterialX/PyMaterialX<MODULE>
# into the package, linked to the MaterialX frameworks named. The files of
# one module compile in parallel.
build() {
    module=$1
    shift
    echo "Building PyMaterialX$module ..."
    objects=""
    for file in "$SOURCE/source/PyMaterialX/PyMaterialX$module"/*.cpp; do
        object="$BUILD/${module}_$(basename "$file" .cpp).o"
        # shellcheck disable=SC2086 # the flags are meant to split into words
        clang++ $CXXFLAGS -c "$file" -o "$object" &
        objects="$objects $object"
    done
    wait
    frameworks=""
    for framework in "$@"; do
        frameworks="$frameworks -framework $framework"
    done
    output="$PACKAGE/PyMaterialX$module.$PYTHON_TAG.so"
    # shellcheck disable=SC2086
    clang++ $LDFLAGS $objects $frameworks -o "$output"
    codesign --force --sign - --timestamp=none "$output" 2> /dev/null
}
build Core MaterialXCore
build Format MaterialXCore MaterialXFormat

cp "$SOURCE/python/MaterialX/"*.py "$PACKAGE/"
cp -R "$PYBIND11/pybind11" "$VENDOR/include/"

# Check that the modules link nothing outside macOS and SwiftUsd's MaterialX.
for module in "$PACKAGE"/*.so; do
    FOREIGN=$(otool -L "$module" | tail -n +2 | awk '{print $1}' \
        | grep -v -e '^/usr/lib/' -e '^/System/Library/' -e '^@rpath/MaterialX' || true)
    if [ -n "$FOREIGN" ]; then
        echo "$(basename "$module") links unexpected libraries:" >&2
        echo "$FOREIGN" >&2
        exit 1
    fi
done

rm -rf "$SOURCE" "$BUILD"
echo "$BUILT_FROM" > "$STAMP"
echo "Done: Vendor/PyMaterialX/site-packages/MaterialX is MaterialX $MATERIALX_TAG for Python 3.13."
