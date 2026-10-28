#!/bin/sh
#
# build-ocio.sh: builds OpenColorIO as Vendor/OpenColorIO/OpenColorIO.xcframework.
#
# Run it once after cloning the repository (after fetch-swiftusd.sh), and
# again after changing OCIO_TAG below. Packages/MargolariaKit depends on the
# xcframework by path, so nothing builds until this has run. A build takes a
# minute or two; a second run with the same tag does nothing.
#
# Why build it: SwiftUsd doesn't include OpenColorIO (PLAN.md §3), and there
# is no prebuilt macOS framework of it to depend on.
#
# What it makes: one dynamic framework, macOS arm64 only, like SwiftUsd's
# (the app is Apple silicon only, PLAN.md §7.1). OCIO's own dependencies
# (yaml-cpp, expat, pystring, Imath, minizip-ng, zlib) are built from source
# by OCIO's CMake (OCIO_INSTALL_EXT_PACKAGES=ALL) and linked in statically,
# with their symbols hidden. So the framework needs nothing outside macOS,
# never picks up a Homebrew copy of a dependency, and its Imath can't clash
# with SwiftUsd's Imath.framework. The configs (ACES studio and CG) are built
# into the library, so there are no config files to ship.
#
# The framework is signed ad hoc here, so tests can load it; Xcode re-signs it
# with our identity when it embeds it in the app (PLAN.md §7.1).
#
# Usage:
#   scripts/build-ocio.sh
#   OCIO_URL=/path/to/an/OpenColorIO/clone scripts/build-ocio.sh   # clone from a local copy

set -eu

# The OpenColorIO release we build. 2.5 is the VFX Reference Platform CY2026
# version, the generation of OpenUSD 26.08 and MaterialX 1.39.5; its latest
# built-in studio config is ACES 2.0 (studio-config-v4.0.0_aces-v2.0_ocio-v2.5).
OCIO_TAG=v2.5.2
OCIO_URL=${OCIO_URL:-https://github.com/AcademySoftwareFoundation/OpenColorIO.git}

# Must match Config/Base.xcconfig.
DEPLOYMENT_TARGET=15.0

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENDOR="$ROOT/Vendor/OpenColorIO"
SOURCE="$VENDOR/source"
BUILD="$VENDOR/build"
INSTALL="$VENDOR/install"
FRAMEWORK="$VENDOR/framework/OpenColorIO.framework"
XCFRAMEWORK="$VENDOR/OpenColorIO.xcframework"
STAMP="$VENDOR/built-tag"

if [ -d "$XCFRAMEWORK" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$OCIO_TAG" ]; then
    echo "Vendor/OpenColorIO is already OpenColorIO $OCIO_TAG."
    exit 0
fi

for tool in cmake ninja git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "build-ocio.sh needs $tool (brew install $tool)." >&2
        exit 1
    fi
done

rm -rf "$VENDOR"
mkdir -p "$VENDOR"

# A shallow clone of one tag; we don't need OCIO's history.
echo "Cloning OpenColorIO $OCIO_TAG from $OCIO_URL ..."
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$OCIO_TAG" "$OCIO_URL" "$SOURCE"

# Only the library: no command-line apps, Python bindings, docs or tests.
# OCIO_USE_SOVERSION=OFF names the library libOpenColorIO.dylib, which
# becomes the framework's binary.
#
# The linker flag exports only OCIO's own symbols (all in the versioned
# namespace OpenColorIO_v2_5, so `*OpenColorIO_v2_*` matches every mangled
# name). Without it, the static zlib's C functions are exported too.
echo "Building (this takes a minute or two) ..."
cmake -S "$SOURCE" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SHARED_LINKER_FLAGS='-Wl,-exported_symbol,*OpenColorIO_v2_*' \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DBUILD_SHARED_LIBS=ON \
    -DOCIO_INSTALL_EXT_PACKAGES=ALL \
    -DOCIO_USE_SOVERSION=OFF \
    -DOCIO_BUILD_APPS=OFF \
    -DOCIO_BUILD_PYTHON=OFF \
    -DOCIO_BUILD_OPENFX=OFF \
    -DOCIO_BUILD_DOCS=OFF \
    -DOCIO_BUILD_TESTS=OFF \
    -DOCIO_BUILD_GPU_TESTS=OFF \
    > "$VENDOR/cmake.log"
cmake --build "$BUILD" > "$VENDOR/build.log"
cmake --install "$BUILD" > "$VENDOR/install.log"

# A macOS framework is a versioned bundle: the real files live in
# Versions/A, and the top level holds symlinks to them.
echo "Making the framework ..."
VERSIONED="$FRAMEWORK/Versions/A"
mkdir -p "$VERSIONED/Headers" "$VERSIONED/Resources"
cp "$INSTALL/lib/libOpenColorIO.dylib" "$VERSIONED/OpenColorIO"
cp "$INSTALL/include/OpenColorIO/"*.h "$VERSIONED/Headers/"
cp "$SOURCE/LICENSE" "$VERSIONED/Resources/LICENSE"
ln -s A "$FRAMEWORK/Versions/Current"
ln -s Versions/Current/OpenColorIO "$FRAMEWORK/OpenColorIO"
ln -s Versions/Current/Headers "$FRAMEWORK/Headers"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"

# Where the app finds the library at run time: in its Frameworks folder,
# through the app's @rpath, like SwiftUsd's frameworks.
install_name_tool -id @rpath/OpenColorIO.framework/Versions/A/OpenColorIO "$VERSIONED/OpenColorIO"

# The version without the leading "v", for the bundle's Info.plist.
VERSION=${OCIO_TAG#v}
cat > "$VERSIONED/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>OpenColorIO</string>
    <key>CFBundleIdentifier</key>
    <string>org.opencolorio.OpenColorIO</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>OpenColorIO</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>$DEPLOYMENT_TARGET</string>
</dict>
</plist>
EOF

# Check that it links nothing outside macOS (a Homebrew library would load
# on this Mac and fail on every other).
FOREIGN=$(otool -L "$VERSIONED/OpenColorIO" | tail -n +2 | awk '{print $1}' \
    | grep -v -e '^/usr/lib/' -e '^/System/Library/' -e '^@rpath/OpenColorIO.framework/' || true)
if [ -n "$FOREIGN" ]; then
    echo "OpenColorIO links libraries outside macOS:" >&2
    echo "$FOREIGN" >&2
    exit 1
fi

codesign --force --sign - --timestamp=none "$FRAMEWORK"
xcodebuild -create-xcframework -framework "$FRAMEWORK" -output "$XCFRAMEWORK" > /dev/null

# The build folders are about 1 GB; only the xcframework is needed.
rm -rf "$BUILD" "$INSTALL" "$VENDOR/framework"
echo "$OCIO_TAG" > "$STAMP"
echo "Done: Vendor/OpenColorIO/OpenColorIO.xcframework is OpenColorIO $OCIO_TAG."
