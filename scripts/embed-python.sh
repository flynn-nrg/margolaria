#!/bin/sh
#
# embed-python.sh: Xcode's last build phase for Margolaria (project.yml).
# Puts the MaterialX package in the app, and signs every compiled Python
# module with the app's identity (M6).
#
# Not run by hand: it reads Xcode's build settings from the environment.
#
# Why it's needed: Xcode embeds Python.framework (a package binary target)
# and signs it, but signs only the framework's own binary. The standard
# library's compiled modules (`lib-dynload/*.so`) and libraries (OpenSSL)
# are files inside it that Xcode doesn't know are code, and they keep the
# ad hoc signature fetch-python.sh gave them. Under the Hardened Runtime,
# library validation refuses to load code signed by anyone else than the
# app's team, and notarization refuses an app containing such code
# (PLAN.md §7.1). So each one is signed here, then the framework again, as
# its signature covers the files inside. The same for the MaterialX
# package's two modules, copied from Vendor/PyMaterialX.
#
# What the app gets:
#   Contents/Frameworks/Python.framework       Python 3.13 (fetch-python.sh)
#   Contents/Resources/Python/site-packages/   the MaterialX package
#                                              (build-pymaterialx.sh)
#
# Order (project.yml): the phase's input is the embedded Python.framework,
# so Xcode runs it after copying the framework in; without it, Xcode ran
# both at once. Xcode then signs every embedded framework, Python's again
# (its own binary, and a new seal over the files inside, which keeps their
# signatures from here), and the app last, sealing all of it.

set -eu

APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
FRAMEWORK="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Python.framework"
SITE_PACKAGES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Python/site-packages"

if [ ! -d "$FRAMEWORK" ]; then
    echo "error: $FRAMEWORK is missing; is ScriptKit linked?" >&2
    exit 1
fi

# The MaterialX package, replacing any earlier copy.
rm -rf "$SITE_PACKAGES"
mkdir -p "$SITE_PACKAGES"
cp -R "$SRCROOT/Vendor/PyMaterialX/site-packages/MaterialX" "$SITE_PACKAGES/"

# The identity Xcode signs with: our Developer ID or Apple Development
# certificate, or "-" (ad hoc) when signing is off. A secure timestamp is
# needed for notarization; Debug builds skip it, as it asks Apple's server.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != YES ] || [ -z "$IDENTITY" ]; then
    IDENTITY=-
fi
TIMESTAMP=--timestamp=none
if [ "$CONFIGURATION" = Release ]; then
    TIMESTAMP=--timestamp
fi

# sign FILE: with the app's identity, the Hardened Runtime on.
sign() {
    codesign --force --sign "$IDENTITY" --options runtime "$TIMESTAMP" "$1"
}

# Every Mach-O file, inner ones first: the modules and libraries, then the
# framework. `-type f` skips the symlinks (libssl.dylib -> libssl.3.dylib).
find "$FRAMEWORK/Versions/Current/" "$SITE_PACKAGES" -type f \( -name '*.so' -o -name '*.dylib' \) |
while read -r binary; do
    sign "$binary"
done
sign "$FRAMEWORK/Versions/Current"

echo "Signed Python.framework and the MaterialX package in $(basename "$APP") ($IDENTITY)."
