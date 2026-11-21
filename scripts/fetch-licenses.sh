#!/bin/sh
#
# fetch-licenses.sh: gathers the licence texts of the third-party software
# inside Margolaria.app into App/Licenses, one text file per project. The app
# shows them in Help > Acknowledgements (AcknowledgementsWindow.swift); the
# About panel's credits (App/Credits.html) name the same projects.
#
# The texts are committed, so a build needs no network. Run this again after
# changing a vendored version (the tags below follow the build scripts), or
# after adding a library to the app, and add it to Credits.html too.
#
# Where they come from: the vendored sources when they are on disk
# (scripts/fetch-swiftusd.sh, build-ocio.sh, fetch-python.sh), otherwise each
# project's repository on GitHub, at the version the app ships when it is
# known. The libraries SwiftUsd builds into its frameworks don't record their
# versions in their bundles; the versions below were read from the binaries'
# symbols and strings (OpenVDB's namespace is openvdb::v10_1, OpenSubdiv's
# v3_6_1, OpenEXR's Imf_3_1), and Alembic's and Boost's licences come from
# their main branches. The version matters: OpenVDB was MPL 2.0 until 12,
# and OpenSubdiv took the TOST licence after 3.6.1.
#
# Usage:
#   scripts/fetch-licenses.sh

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENDOR="$ROOT/Vendor"
DEST="$ROOT/App/Licenses"
GITHUB=https://raw.githubusercontent.com

for source in "$VENDOR/SwiftUsd/ACKNOWLEDGEMENTS" "$VENDOR/MaterialX/LICENSE" "$VENDOR/OpenColorIO/source/LICENSE"; do
    if [ ! -f "$source" ]; then
        echo "fetch-licenses.sh needs $source; run the scripts that fetch and build Vendor first." >&2
        exit 1
    fi
done
PYTHON_LICENSE=$(find "$VENDOR/Python/Python.xcframework" -path '*/lib/python3.*/LICENSE.txt' | head -1)
if [ -z "$PYTHON_LICENSE" ]; then
    echo "fetch-licenses.sh needs Vendor/Python; run scripts/fetch-python.sh first." >&2
    exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"

# One file: a heading (the project and where its licence comes from), then
# the texts. Usage: write NAME HEADING SOURCE...; a SOURCE is a file on
# disk, or an https URL.
write() {
    file="$DEST/$1.txt"
    printf '%s\n\n' "$2" > "$file"
    shift 2
    for source in "$@"; do
        case "$source" in
            https://*)
                printf 'From %s\n\n' "$source" >> "$file"
                curl --fail --silent --show-error --location "$source" >> "$file" ;;
            *)
                cat "$source" >> "$file" ;;
        esac
        printf '\n\n' >> "$file"
    done
    echo "  $(basename "$file")"
}

echo "Writing App/Licenses ..."

# The libraries the app is built on.
write "OpenUSD" "OpenUSD 26.08, with the third-party code it includes" "$VENDOR/SwiftUsd/ACKNOWLEDGEMENTS"
write "SwiftUsd" "SwiftUsd 8.1.0" "$VENDOR/SwiftUsd/NOTICE" "$VENDOR/SwiftUsd/LICENSE"
write "MaterialX" "MaterialX 1.39.5, with the third-party code it includes" \
    "$VENDOR/MaterialX/LICENSE" "$VENDOR/MaterialX/THIRD-PARTY.md"
write "OpenColorIO" "OpenColorIO 2.5.2" "$VENDOR/OpenColorIO/source/LICENSE"

# What OpenColorIO builds into itself (scripts/build-ocio.sh's
# OCIO_INSTALL_EXT_PACKAGES=ALL; the versions are in its cmake.log).
write "expat" "expat 2.7.2 (in OpenColorIO)" "$GITHUB/libexpat/libexpat/R_2_7_2/expat/COPYING"
write "yaml-cpp" "yaml-cpp 0.8.0 (in OpenColorIO)" "$GITHUB/jbeder/yaml-cpp/0.8.0/LICENSE"
write "pystring" "pystring 1.1.4 (in OpenColorIO)" "$GITHUB/imageworks/pystring/v1.1.4/LICENSE"
write "minizip-ng" "minizip-ng 4.0.10 (in OpenColorIO)" "$GITHUB/zlib-ng/minizip-ng/4.0.10/LICENSE"
write "zlib" "zlib 1.3.1 (in OpenColorIO)" "$GITHUB/madler/zlib/v1.3.1/LICENSE"

# Python and what its build bundles. Python's documentation acknowledges the
# software CPython itself includes (OpenSSL, mpdecimal, expat, ...).
write "Python" "Python 3.13" "$PYTHON_LICENSE" "$GITHUB/python/cpython/3.13/Doc/license.rst"
write "Python-Apple-support" "BeeWare's Python-Apple-support, which packages Python for the app" \
    "$GITHUB/beeware/Python-Apple-support/main/LICENSE"
write "XZ Utils" "XZ Utils (liblzma, in Python)" "$GITHUB/tukaani-project/xz/master/COPYING.0BSD"
write "ncurses" "ncurses (in Python)" "$GITHUB/mirror/ncurses/master/COPYING"
write "pybind11" "pybind11 (in MaterialX's Python bindings)" "$GITHUB/pybind/pybind11/master/LICENSE"

# The libraries SwiftUsd builds for OpenUSD.
write "OpenEXR" "OpenEXR 3.1 (in OpenUSD)" "$GITHUB/AcademySoftwareFoundation/openexr/v3.1.11/LICENSE.md"
write "Imath" "Imath 3.1 (in OpenUSD), 3.2.1 (in OpenColorIO)" "$GITHUB/AcademySoftwareFoundation/Imath/v3.1.9/LICENSE.md"
write "OpenSubdiv" "OpenSubdiv 3.6.1 (in OpenUSD)" "$GITHUB/PixarAnimationStudios/OpenSubdiv/v3_6_1/LICENSE.txt"
write "TBB" "Threading Building Blocks 2020.3 (in OpenUSD)" "$GITHUB/uxlfoundation/oneTBB/v2020.3/LICENSE"
write "OpenVDB" "OpenVDB 10.1 (in OpenUSD). Its source: https://github.com/AcademySoftwareFoundation/openvdb" \
    "$GITHUB/AcademySoftwareFoundation/openvdb/v10.1.0/LICENSE"
write "Alembic" "Alembic (in OpenUSD)" "$GITHUB/alembic/alembic/master/LICENSE.txt"
write "Embree" "Embree 4.3.3 (in OpenUSD)" "$GITHUB/RenderKit/embree/v4.3.3/LICENSE.txt"
write "Blosc" "Blosc 1.21.6 (in OpenUSD)" "$GITHUB/Blosc/c-blosc/v1.21.6/LICENSE.txt"
write "Boost" "Boost (in OpenUSD)" "$GITHUB/boostorg/boost/master/LICENSE_1_0.txt"

# Artwork: the paintbrush in the app's icon (App/Margolaria.icon). CC0
# asks for no notice; this says where it came from.
cat > "$DEST/Paint Brush icon.txt" <<'END'
"Paint Brush", the paintbrush in Margolaria's icon

By Christoffer Skogsmo, from The Noun Project (https://thenounproject.com/icon/250803).
Found on Wikimedia Commons: https://commons.wikimedia.org/wiki/File:Paint_Brush_-_The_Noun_Project.svg

Dedicated to the public domain under the Creative Commons CC0 1.0 Universal
Public Domain Dedication: https://creativecommons.org/publicdomain/zero/1.0/legalcode
END
echo "  Paint Brush icon.txt"

echo "Done. SQLite, in Python, is in the public domain and has no licence text."
