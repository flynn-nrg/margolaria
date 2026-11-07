#!/bin/sh
#
# build-materialx-genosl.sh: builds MaterialX's OSL shader generators as
# Vendor/MaterialXGenOsl/MaterialXGenOsl.xcframework, with the compiled OSL
# library the network form needs.
#
# Run it once after cloning the repository, after fetch-swiftusd.sh and
# build-osl.sh, and again after changing MATERIALX_TAG below.
# Packages/MargolariaKit depends on the xcframework by path, so nothing
# builds until this has run. A second run with the same tag does nothing.
#
# Why build it: SwiftUsd ships MaterialX's MSL and GLSL generators but not
# its OSL ones (PLAN.md §8.6, M5d). MaterialX 1.39.5's MaterialXGenOsl
# sources hold both: OslShaderGenerator (one shader per material, the
# whole graph inlined) and OslNetworkShaderGenerator (a shader group, one
# compiled shader per node). They are compiled here against SwiftUsd's
# MaterialX headers and linked to its MaterialXCore, MaterialXFormat and
# MaterialXGenShader frameworks, so they share one MaterialX at run time.
#
# What it makes: one dynamic framework, macOS arm64 only, like SwiftUsd's,
# with these resources:
#   genoslnetwork/*.oso                   every node of MaterialX's library
#                                         compiled for the network form, by
#                                         MaterialX's LibsToOso tool and
#                                         build-osl.sh's oslc
#   genoslnetwork/genoslnetwork_impl.mtlx the implementations that point
#                                         the network generator at them
#   margolarialib/margolaria_cmlib.mtlx   Margolaria's colour transforms to
#                                         ACEScg, which MaterialX lacks, from
#                                         Packages/MargolariaKit/Libraries;
#                                         compiled for networks with the rest
#
# The framework is signed ad hoc here, so tests can load it; Xcode re-signs
# it with our identity when it embeds it in the app (PLAN.md §7.1).
#
# Usage:
#   scripts/build-materialx-genosl.sh
#   MATERIALX_URL=/path/to/a/MaterialX/clone scripts/build-materialx-genosl.sh

set -eu

# The MaterialX release bundled in SwiftUsd 8.1.0 (scripts/fetch-swiftusd.sh).
# It must match exactly: the generators use MaterialX's C++ classes directly.
MATERIALX_TAG=v1.39.5
MATERIALX_URL=${MATERIALX_URL:-https://github.com/AcademySoftwareFoundation/MaterialX.git}

# Must match Config/Base.xcconfig.
DEPLOYMENT_TARGET=15.0

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENDOR="$ROOT/Vendor/MaterialXGenOsl"
SOURCE="$VENDOR/source"
BUILD="$VENDOR/build"
FRAMEWORK="$VENDOR/framework/MaterialXGenOsl.framework"
XCFRAMEWORK="$VENDOR/MaterialXGenOsl.xcframework"
STAMP="$VENDOR/built-tag"

# SwiftUsd's MaterialX: headers, frameworks and data libraries.
SWIFTUSD="$ROOT/Vendor/SwiftUsd/swift-package"
HEADERS="$SWIFTUSD/Sources/_OpenUSD_SwiftBindingHelpers/include"
LIBRARIES="$SWIFTUSD/Libraries"
MTLX_LIBRARIES="$LIBRARIES/Usd_UsdMtlx.xcframework/macos-arm64/Usd_UsdMtlx.framework/Versions/A/Resources/MaterialX_Libraries"

# Margolaria's own library (the transforms to ACEScg), in a folder named as
# MaterialX's library folders are.
OWN_LIBRARY="$ROOT/Packages/MargolariaKit/Libraries/margolarialib"

# What the build is of: the MaterialX release and our library's contents,
# so a change to either builds again.
BUILT_FROM="$MATERIALX_TAG $(cat "$OWN_LIBRARY"/*.mtlx | shasum | cut -d' ' -f1)"

# build-osl.sh's tools.
OSLC="$ROOT/Vendor/OSL/install/bin/oslc"
OSL_SHADERS="$ROOT/Vendor/OSL/install/share/OSL/shaders"

if [ -d "$XCFRAMEWORK" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$BUILT_FROM" ]; then
    echo "Vendor/MaterialXGenOsl is already MaterialX $MATERIALX_TAG."
    exit 0
fi

if [ ! -d "$HEADERS/MaterialXGenShader" ]; then
    echo "Run scripts/fetch-swiftusd.sh first." >&2
    exit 1
fi
if [ ! -x "$OSLC" ]; then
    echo "Run scripts/build-osl.sh first." >&2
    exit 1
fi

rm -rf "$VENDOR"
mkdir -p "$VENDOR" "$BUILD"

# A shallow, sparse clone of the one folder we need.
echo "Cloning MaterialX $MATERIALX_TAG's OSL generator from $MATERIALX_URL ..."
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$MATERIALX_TAG" \
    --filter=blob:none --sparse "$MATERIALX_URL" "$SOURCE"
git -C "$SOURCE" sparse-checkout set source/MaterialXGenOsl

# The compiler flags MaterialX's CMake uses for a shared release library:
# C++17, symbols hidden unless marked MX_GENOSL_API (MATERIALX_GENOSL_EXPORTS
# marks them for export). `-I "$SOURCE/source"` resolves the sources'
# own <MaterialXGenOsl/...> includes.
CXXFLAGS="-std=c++17 -O2 -arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET -fvisibility=hidden
    -I$SOURCE/source -I$HEADERS"
LINK_MATERIALX="-F$LIBRARIES/MaterialXCore.xcframework/macos-arm64
    -F$LIBRARIES/MaterialXFormat.xcframework/macos-arm64
    -F$LIBRARIES/MaterialXGenShader.xcframework/macos-arm64
    -framework MaterialXCore -framework MaterialXFormat -framework MaterialXGenShader"

echo "Building the generators ..."
OBJECTS=""
for file in $(cd "$SOURCE/source/MaterialXGenOsl" && find . -name '*.cpp' ! -name LibsToOso.cpp); do
    object="$BUILD/$(echo "$file" | sed 's|^\./||; s|/|_|g; s|\.cpp$|.o|')"
    # shellcheck disable=SC2086 # the flags are meant to split into words
    clang++ $CXXFLAGS -DMATERIALX_GENOSL_EXPORTS -c "$SOURCE/source/MaterialXGenOsl/$file" -o "$object"
    OBJECTS="$OBJECTS $object"
done

# A macOS framework is a versioned bundle: the real files live in
# Versions/A, and the top level holds symlinks to them. Headers keep their
# folders (Nodes/OsoNode.h), so <MaterialXGenOsl/Nodes/OsoNode.h> resolves.
echo "Making the framework ..."
VERSIONED="$FRAMEWORK/Versions/A"
mkdir -p "$VERSIONED/Headers/Nodes" "$VERSIONED/Resources/genoslnetwork" "$VERSIONED/Resources/margolarialib"
cp "$OWN_LIBRARY"/*.mtlx "$VERSIONED/Resources/margolarialib/"
# shellcheck disable=SC2086
clang++ -dynamiclib -arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET $OBJECTS $LINK_MATERIALX \
    -install_name @rpath/MaterialXGenOsl.framework/Versions/A/MaterialXGenOsl \
    -o "$VERSIONED/MaterialXGenOsl"
(cd "$SOURCE/source/MaterialXGenOsl" && find . -name '*.h' -exec cp {} "$VERSIONED/Headers/{}" \;)
ln -s A "$FRAMEWORK/Versions/Current"
ln -s Versions/Current/MaterialXGenOsl "$FRAMEWORK/MaterialXGenOsl"
ln -s Versions/Current/Headers "$FRAMEWORK/Headers"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"

# LibsToOso: MaterialX's tool that compiles every node of the library for
# the network form. Built against the framework just made, run once, not
# kept. It calls oslc for each node (about a thousand), which takes a few
# minutes.
echo "Compiling MaterialX's OSL library for the network form (a few minutes) ..."
# shellcheck disable=SC2086
clang++ $CXXFLAGS "$SOURCE/source/MaterialXGenOsl/LibsToOso.cpp" $LINK_MATERIALX \
    "$VERSIONED/MaterialXGenOsl" \
    -Wl,-rpath,"$FRAMEWORK/.." -Wl,-rpath,"$LIBRARIES/MaterialXCore.xcframework/macos-arm64" \
    -Wl,-rpath,"$LIBRARIES/MaterialXFormat.xcframework/macos-arm64" \
    -Wl,-rpath,"$LIBRARIES/MaterialXGenShader.xcframework/macos-arm64" \
    -o "$BUILD/LibsToOso"
NETWORK="$VERSIONED/Resources/genoslnetwork"
# --libraryRelativeOsoPath: what the implementations' `file` says, found
# at run time through the framework's Resources folder on the generator's
# source search path.
"$BUILD/LibsToOso" \
    --path "$MTLX_LIBRARIES" \
    --path "$VERSIONED/Resources" \
    --library margolarialib \
    --outputOsoPath "$NETWORK" \
    --outputMtlxPath "$NETWORK" \
    --libraryRelativeOsoPath genoslnetwork \
    --oslCompilerPath "$OSLC" \
    --oslIncludePath "$OSL_SHADERS" \
    > "$VENDOR/libstooso.log" 2>&1 || {
    echo "LibsToOso failed; see Vendor/MaterialXGenOsl/libstooso.log." >&2
    exit 1
}
# Only the compiled shaders are kept; LibsToOso writes each source (oslc
# reads it from disk) and an error file per shader next to them.
rm -f "$NETWORK"/*.osl "$NETWORK"/*_compile_errors.txt

# The version without the leading "v", for the bundle's Info.plist.
VERSION=${MATERIALX_TAG#v}
cat > "$VERSIONED/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MaterialXGenOsl</string>
    <key>CFBundleIdentifier</key>
    <string>eu.emerald-isle.margolaria.MaterialXGenOsl</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MaterialXGenOsl</string>
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

# Check that it links nothing outside macOS and SwiftUsd's MaterialX.
FOREIGN=$(otool -L "$VERSIONED/MaterialXGenOsl" | tail -n +2 | awk '{print $1}' \
    | grep -v -e '^/usr/lib/' -e '^/System/Library/' -e '^@rpath/MaterialX' || true)
if [ -n "$FOREIGN" ]; then
    echo "MaterialXGenOsl links libraries outside macOS:" >&2
    echo "$FOREIGN" >&2
    exit 1
fi

codesign --force --sign - --timestamp=none "$FRAMEWORK"
xcodebuild -create-xcframework -framework "$FRAMEWORK" -output "$XCFRAMEWORK" > /dev/null

rm -rf "$BUILD" "$VENDOR/framework"
echo "$BUILT_FROM" > "$STAMP"
echo "Done: Vendor/MaterialXGenOsl/MaterialXGenOsl.xcframework is MaterialX $MATERIALX_TAG's OSL generators."
