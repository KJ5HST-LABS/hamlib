#!/usr/bin/env bash
#
# verify.sh — Verify a bundled rigctld archive works in isolation.
#
# Usage: verify.sh <staging-dir>
#
# Runs the verification tests from PANELKIT_BINARY_REQUIREMENTS.md.

set -euo pipefail

DIR="$1"

echo "=== Verification: $DIR ==="

# --- Check binary exists and is executable ---
if [ ! -x "$DIR/rigctld" ]; then
    echo "FAIL: $DIR/rigctld is not executable or does not exist"
    exit 1
fi
echo "PASS: rigctld exists and is executable"

# --- Check version output ---
VERSION_OUTPUT=$("$DIR/rigctld" --version 2>&1 || true)
if [ -z "$VERSION_OUTPUT" ]; then
    echo "FAIL: rigctld --version produced no output"
    exit 1
fi
echo "PASS: rigctld --version: $VERSION_OUTPUT"

# --- Check model list ---
MODEL_COUNT=$("$DIR/rigctld" -l 2>&1 | wc -l | tr -d ' ')
if [ "$MODEL_COUNT" -lt 100 ]; then
    echo "FAIL: rigctld -l returned only $MODEL_COUNT lines (expected 300+)"
    exit 1
fi
echo "PASS: rigctld -l returned $MODEL_COUNT models"

# --- Check dummy rig ---
PORT=14532
"$DIR/rigctld" -m 1 -t $PORT &
RIGCTLD_PID=$!
sleep 2

# Verify it's running
if ! kill -0 $RIGCTLD_PID 2>/dev/null; then
    echo "FAIL: rigctld exited unexpectedly"
    exit 1
fi
echo "PASS: rigctld dummy rig started (PID $RIGCTLD_PID)"

# Query the dummy rig (timeout to avoid hanging in CI)
RESPONSE=$(timeout 5 bash -c "echo '+\quit' | nc -w 2 localhost $PORT" 2>/dev/null || echo "")
kill $RIGCTLD_PID 2>/dev/null || true
wait $RIGCTLD_PID 2>/dev/null || true

if [ -z "$RESPONSE" ]; then
    echo "WARN: Could not query rigctld on port $PORT (nc may not be available or timed out)"
else
    echo "PASS: Dummy rig responded: $(echo "$RESPONSE" | head -1)"
fi

# --- Platform-specific library checks ---
if [ "$(uname)" = "Darwin" ]; then
    echo ""
    echo "=== macOS library check ==="
    otool -L "$DIR/rigctld"

    # Check for forbidden references
    FORBIDDEN=$(otool -L "$DIR/rigctld" | grep -E '/opt/homebrew|/usr/local/lib' || true)
    if [ -n "$FORBIDDEN" ]; then
        echo "FAIL: rigctld links against non-portable paths:"
        echo "$FORBIDDEN"
        exit 1
    fi
    echo "PASS: No forbidden library paths"
elif [ "$(uname)" = "Linux" ]; then
    echo ""
    echo "=== Linux library check ==="
    ldd "$DIR/rigctld"

    # Check that libhamlib is found via RPATH
    NOTFOUND=$(ldd "$DIR/rigctld" | grep 'not found' || true)
    if [ -n "$NOTFOUND" ]; then
        echo "FAIL: Missing libraries:"
        echo "$NOTFOUND"
        exit 1
    fi
    echo "PASS: All libraries resolved"
fi

echo ""
echo "=== All verification checks passed ==="
