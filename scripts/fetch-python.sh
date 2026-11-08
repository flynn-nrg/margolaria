#!/bin/sh
#
# fetch-python.sh: puts Python 3.13 in Vendor/Python, as
# Vendor/Python/Python.xcframework, for embedding in Margolaria (M6).
#
# Run it once after cloning the repository, and again after changing
# PYTHON_BUILD below. Packages/MargolariaKit depends on the xcframework by
# path, so nothing builds until this has run. A second run with the same
# build does nothing.
#
# Where it comes from: BeeWare's Python-Apple-support, which re-bundles
# python.org's macOS build as a relocatable Python.framework (no IDLE,
# Tkinter or turtle), made for embedding in apps (PLAN.md §8.7). The
# framework holds the interpreter (`Python`), its headers, and the
# standard library with its compiled modules (`lib/python3.13`,
# `lib-dynload/*.so`).
#
# What it changes:
#   - only arm64 is kept (the app is Apple silicon only, PLAN.md §7.1),
#     about half the size;
#   - the standard library's tests (35 MB) and CPython's own test modules
#     (`_testcapi`, `xxlimited`, ...), the command-line `python3` and
#     the framework's `Python.app` are removed: Margolaria runs Python
#     inside itself, and every executable left in the bundle would be one
#     more to sign;
#   - everything is signed again ad hoc, as thinning changes the files, so
#     tests can load it. Xcode's build signs it with our identity
#     (scripts/embed-python.sh).
#
# Usage:
#   scripts/fetch-python.sh

set -eu

# The Python-Apple-support build: Python 3.13 (PLAN.md §8.7), BeeWare's
# build number, and the archive's SHA-256, so a changed download is refused.
PYTHON_VERSION=3.13
PYTHON_BUILD=b18
PYTHON_SHA256=61971e9dc3258c76033ef800412989ec92e14cf0653f2a19e006d167d5a1436c
PYTHON_URL="https://github.com/beeware/Python-Apple-support/releases/download/$PYTHON_VERSION-$PYTHON_BUILD/Python-$PYTHON_VERSION-macOS-support.$PYTHON_BUILD.tar.gz"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENDOR="$ROOT/Vendor/Python"
XCFRAMEWORK="$VENDOR/Python.xcframework"
STAMP="$VENDOR/built-from"
BUILT_FROM="$PYTHON_VERSION-$PYTHON_BUILD"

if [ -d "$XCFRAMEWORK" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$BUILT_FROM" ]; then
    echo "Vendor/Python is already Python $BUILT_FROM."
    exit 0
fi

rm -rf "$VENDOR"
mkdir -p "$VENDOR/download"

echo "Downloading Python $PYTHON_VERSION ($PYTHON_BUILD) ..."
curl --fail --silent --show-error --location -o "$VENDOR/download/python.tar.gz" "$PYTHON_URL"
echo "$PYTHON_SHA256  $VENDOR/download/python.tar.gz" | shasum -a 256 -c --quiet
tar -xzf "$VENDOR/download/python.tar.gz" -C "$VENDOR/download"

FRAMEWORK="$VENDOR/download/Python.xcframework/macos-arm64_x86_64/Python.framework"
VERSIONED="$FRAMEWORK/Versions/$PYTHON_VERSION"

echo "Removing what Margolaria doesn't use ..."
rm -rf "$VERSIONED/lib/python$PYTHON_VERSION/test" \
       "$VERSIONED/lib/python$PYTHON_VERSION/lib-dynload/_test"* \
       "$VERSIONED/lib/python$PYTHON_VERSION/lib-dynload/xx"* \
       "$VERSIONED/lib/python$PYTHON_VERSION/lib-dynload/_ctypes_test"* \
       "$VERSIONED/bin" \
       "$VERSIONED/Resources/Python.app"

# Every Mach-O file (the interpreter, the modules, OpenSSL's and ncurses'
# libraries): arm64 only, then signed ad hoc. Symlinks (libssl.dylib ->
# libssl.3.dylib) are skipped by `-type f`.
echo "Keeping arm64 only ..."
find "$VERSIONED" -type f \( -name '*.so' -o -name '*.dylib' -o -name Python \) | while read -r binary; do
    if lipo -info "$binary" 2>/dev/null | grep -q x86_64; then
        lipo -thin arm64 "$binary" -output "$binary.arm64"
        mv "$binary.arm64" "$binary"
    fi
    codesign --force --sign - --timestamp=none "$binary" 2> /dev/null
done
# The framework itself last, as its signature covers the files inside.
codesign --force --sign - --timestamp=none "$VERSIONED" 2> /dev/null

# A new xcframework from the thinned framework, so its slice is named
# macos-arm64 like SwiftUsd's.
xcodebuild -create-xcframework -framework "$FRAMEWORK" -output "$XCFRAMEWORK" > /dev/null
cp "$VENDOR/download/VERSIONS" "$VENDOR/VERSIONS"
rm -rf "$VENDOR/download"

echo "$BUILT_FROM" > "$STAMP"
echo "Done: Vendor/Python/Python.xcframework is Python $PYTHON_VERSION ($PYTHON_BUILD), arm64,"
echo "$(du -sh "$XCFRAMEWORK" | cut -f1) in all."
