#!/usr/bin/env bash
#
# bundle-macos.sh — Rewrite dylib paths and ad-hoc sign for self-contained distribution.
#
# Usage: bundle-macos.sh <install-prefix> <staging-dir>
#
# The install prefix is where `make install` put files (e.g., hamlib-src/install).
# The staging dir is where the flat archive layout will be assembled.

set -euo pipefail

PREFIX="$1"
STAGING="$2"

mkdir -p "$STAGING/lib"

# --- Copy binary ---
cp "$PREFIX/bin/rigctld" "$STAGING/rigctld"
chmod 755 "$STAGING/rigctld"

# --- Copy libraries ---
# Copy all libhamlib dylibs and symlinks, preserving symlink structure
for f in "$PREFIX/lib"/libhamlib*dylib*; do
    if [ -L "$f" ]; then
        # Preserve symlinks
        cp -P "$f" "$STAGING/lib/"
    elif [ -f "$f" ]; then
        cp "$f" "$STAGING/lib/"
    fi
done

# --- Rewrite library paths ---
# Find the actual versioned dylib (not a symlink)
REAL_DYLIB=$(find "$STAGING/lib" -name 'libhamlib.*.dylib' -not -type l | head -1)
REAL_DYLIB_NAME=$(basename "$REAL_DYLIB")

# Get the current install name baked into rigctld
OLD_LIBPATH=$(otool -L "$STAGING/rigctld" | grep libhamlib | awk '{print $1}')

echo "Rewriting library paths..."
echo "  Old path: $OLD_LIBPATH"
echo "  New path: @loader_path/lib/$REAL_DYLIB_NAME"

# Rewrite rigctld's reference to libhamlib
install_name_tool -change \
    "$OLD_LIBPATH" \
    "@loader_path/lib/$REAL_DYLIB_NAME" \
    "$STAGING/rigctld"

# Rewrite libhamlib's install name (identity)
install_name_tool -id \
    "@loader_path/$REAL_DYLIB_NAME" \
    "$STAGING/lib/$REAL_DYLIB_NAME"

# --- Verify no external references remain ---
echo ""
echo "Checking for external references..."
EXTERNAL=$(otool -L "$STAGING/rigctld" | grep -v '@loader_path' | grep -v '/usr/lib/' | grep -v 'libSystem' | grep -v "$STAGING/rigctld:" || true)
if [ -n "$EXTERNAL" ]; then
    echo "WARNING: External references found in rigctld:"
    echo "$EXTERNAL"
    # Don't fail — some system libs are expected
fi

EXTERNAL_LIB=$(otool -L "$STAGING/lib/$REAL_DYLIB_NAME" | grep -v '@loader_path' | grep -v '/usr/lib/' | grep -v 'libSystem' | grep -v "$REAL_DYLIB_NAME:" || true)
if [ -n "$EXTERNAL_LIB" ]; then
    echo "WARNING: External references found in $REAL_DYLIB_NAME:"
    echo "$EXTERNAL_LIB"
fi

# --- Ad-hoc code sign ---
# MUST happen AFTER install_name_tool (it silently fails on signed binaries)
# Do NOT use --options runtime (hardened runtime) with ad-hoc signing — causes SIGABRT
echo ""
echo "Ad-hoc signing..."
codesign -s - --force "$STAGING/lib/$REAL_DYLIB_NAME"
# Sign symlink targets only if they point to a different file
for f in "$STAGING/lib"/libhamlib*dylib; do
    if [ -L "$f" ]; then
        # Symlinks don't need signing, only real files
        continue
    fi
    codesign -s - --force "$f" 2>/dev/null || true
done
codesign -s - --force "$STAGING/rigctld"

echo ""
echo "Bundle complete. Staging directory:"
ls -la "$STAGING/"
ls -la "$STAGING/lib/"

echo ""
echo "Final otool -L rigctld:"
otool -L "$STAGING/rigctld"
