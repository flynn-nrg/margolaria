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
#
# Only what changed: the phase runs on every build, but when nothing else
# changed, Xcode doesn't sign the app again. Copying the package or
# signing a module then would break the app's seal ("a sealed resource is
# missing or invalid", found in M6b). So the package is copied only when
# Vendor's differs from what was copied last, and a file is signed only if
# it isn't signed as it should be already.

set -eu

APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
FRAMEWORK="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Python.framework"
SITE_PACKAGES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Python/site-packages"

if [ ! -d "$FRAMEWORK" ]; then
    echo "error: $FRAMEWORK is missing; is ScriptKit linked?" >&2
    exit 1
fi

# The MaterialX package, replacing any earlier copy if Vendor's has changed
# since: its checksum is kept in Xcode's temporary folder for the target,
# outside the app.
SOURCE="$SRCROOT/Vendor/PyMaterialX/site-packages"
STAMP="$TARGET_TEMP_DIR/embed-python-site-packages.sha"
CHECKSUM=$(cd "$SOURCE" && find MaterialX -type f | LC_ALL=C sort | xargs shasum | shasum | cut -d ' ' -f 1)
if [ ! -d "$SITE_PACKAGES/MaterialX" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$CHECKSUM" ]; then
    rm -rf "$SITE_PACKAGES"
    mkdir -p "$SITE_PACKAGES" "$(dirname "$STAMP")"
    cp -R "$SOURCE/MaterialX" "$SITE_PACKAGES/"
    echo "$CHECKSUM" > "$STAMP"
fi

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

# signed FILE: true if FILE is signed as sign() would: the Hardened
# Runtime on, our team's (any signature will do when signing is ad hoc),
# with a secure timestamp in Release. fetch-python.sh's and
# build-pymaterialx.sh's ad hoc signatures don't have the runtime flag.
signed() {
    info=$(codesign -dvv "$1" 2>&1) || return 1
    case "$info" in *"(runtime)"*) ;; *) return 1 ;; esac
    [ "$IDENTITY" = - ] && return 0
    case "$info" in *"TeamIdentifier=${DEVELOPMENT_TEAM:-}"*) ;; *) return 1 ;; esac
    if [ "$CONFIGURATION" = Release ]; then
        case "$info" in *"Timestamp="*) ;; *) return 1 ;; esac
    fi
    return 0
}

# sign FILE: with the app's identity, the Hardened Runtime on.
sign() {
    codesign --force --sign "$IDENTITY" --options runtime "$TIMESTAMP" "$1"
}

# Every Mach-O file, inner ones first: the modules and libraries, then the
# framework, signed again if any of them was. `-type f` skips the symlinks
# (libssl.dylib -> libssl.3.dylib). The count goes through a file, as the
# loop runs in a subshell (the pipe's).
COUNT_FILE="$TARGET_TEMP_DIR/embed-python-signed.count"
mkdir -p "$TARGET_TEMP_DIR"
: > "$COUNT_FILE"
find "$FRAMEWORK/Versions/Current/" "$SITE_PACKAGES" -type f \( -name '*.so' -o -name '*.dylib' \) |
while read -r binary; do
    if ! signed "$binary"; then
        sign "$binary"
        echo x >> "$COUNT_FILE"
    fi
done
SIGNED=$(wc -l < "$COUNT_FILE" | tr -d ' ')
if [ "$SIGNED" -gt 0 ] || ! signed "$FRAMEWORK/Versions/Current"; then
    sign "$FRAMEWORK/Versions/Current"
fi

echo "Signed $SIGNED Python modules and libraries in $(basename "$APP") ($IDENTITY)."
