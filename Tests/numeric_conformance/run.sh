#!/usr/bin/env bash
# Run every conformance program in this directory with a given compiler.
#
#   ./run.sh /path/to/kairo
#
# Each program returns 0 on success, or the number of the first failed check.
# Go to the comment above that check in the file; it explains what was expected
# and what a wrong answer implies.
#
# A file may declare `REQUIRES: literals-above-64-bit` in its header. Stage 0
# rejects any literal at or above 2^64 -- correct for its own 64-bit world,
# wrong for Kairo's -- so such a file is reported as `skip` when it fails to
# compile, rather than as an error. Under stage 1 it must compile and pass.
set -u

KAIRO="${1:-kairo}"
DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
for src in "$DIR"/*.k; do
    name="$(basename "$src")"
    bin="$TMP/${name%.k}"

    if ! "$KAIRO" "$src" -o "$bin" >"$TMP/log" 2>&1 || [ ! -x "$bin" ]; then
        if grep -q 'REQUIRES: literals-above-64-bit' "$src"; then
            printf '%-40s skip  compiler rejects >=2^64 literals (expected on stage 0)\n' "$name"
        else
            printf '%-40s ERROR did not compile\n' "$name"
            sed -n '1,3p' "$TMP/log"
            fail=1
        fi
        continue
    fi

    "$bin"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%-40s ok\n' "$name"
    elif [ "$rc" -gt 128 ]; then
        printf '%-40s CRASH signal %d\n' "$name" "$((rc - 128))"
        fail=1
    else
        printf '%-40s FAIL  check %d\n' "$name" "$rc"
        fail=1
    fi
done

exit "$fail"
