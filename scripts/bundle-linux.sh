#!/usr/bin/env bash
#
# bundle-linux.sh — Copy rigctld + libhamlib and set RPATH for self-contained distribution.
#
# Usage: bundle-linux.sh <install-prefix> <staging-dir>

set -euo pipefail

PREFIX="$1"
STAGING="$2"

mkdir -p "$STAGING/lib"

# --- Copy binary ---
cp "$PREFIX/bin/rigctld" "$STAGING/rigctld"
chmod 755 "$STAGING/rigctld"

# --- Copy libraries ---
# Copy all libhamlib shared objects and symlinks, preserving symlink structure
for f in "$PREFIX/lib"/libhamlib.so*; do
    if [ -L "$f" ]; then
        cp -P "$f" "$STAGING/lib/"
    elif [ -f "$f" ]; then
        cp "$f" "$STAGING/lib/"
    fi
done

# --- Set RPATH ---
echo "Setting RPATH to \$ORIGIN/lib..."
patchelf --set-rpath '$ORIGIN/lib' "$STAGING/rigctld"

# --- Verify no missing libraries ---
echo ""
echo "Checking library dependencies..."
ldd "$STAGING/rigctld"

NOTFOUND=$(ldd "$STAGING/rigctld" | grep 'not found' || true)
if [ -n "$NOTFOUND" ]; then
    echo "ERROR: Missing libraries:"
    echo "$NOTFOUND"
    exit 1
fi

# Check that libhamlib resolves from the staging lib/ directory
HAMLIB_RESOLVED=$(LD_LIBRARY_PATH="$STAGING/lib" ldd "$STAGING/rigctld" | grep libhamlib || true)
echo ""
echo "libhamlib resolution: $HAMLIB_RESOLVED"

echo ""
echo "Bundle complete. Staging directory:"
ls -la "$STAGING/"
ls -la "$STAGING/lib/"

echo ""
echo "Final ldd rigctld:"
LD_LIBRARY_PATH="$STAGING/lib" ldd "$STAGING/rigctld"
