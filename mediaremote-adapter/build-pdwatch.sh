#!/usr/bin/env bash
# Build the pdwatch parent-death watchdog as a universal Mach-O binary.
# Output: ./pdwatch alongside this script.
#
# Run from the mediaremote-adapter/ directory (or anywhere):
#   ./build-pdwatch.sh
#
# Re-run any time you change pdwatch.c. The result must be committed
# along with the source so the app bundle picks it up at build time —
# Xcode treats the binary as a plain resource (no compile step) so it
# does not get rebuilt on its own.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ ! -f pdwatch.c ]]; then
    echo "error: pdwatch.c not found in $(pwd)" >&2
    exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
    echo "error: clang not found in PATH (install Xcode Command Line Tools)" >&2
    exit 1
fi

OUT="pdwatch"
echo "Compiling pdwatch.c -> $OUT (universal arm64 + x86_64)..."

clang \
    -arch arm64 \
    -arch x86_64 \
    -O2 \
    -Wall \
    -Wextra \
    -mmacosx-version-min=14.0 \
    -o "$OUT" \
    pdwatch.c

chmod +x "$OUT"

echo "Built:"
ls -lh "$OUT"
echo
echo "Architectures:"
file "$OUT"
echo
echo "Smoke test (--help-style error path):"
./pdwatch || true
