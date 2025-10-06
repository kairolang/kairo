#!/usr/bin/env sh
# POSIX wrapper
# Usage: ./make.sh <args...>

for exe in python3 python py; do
    if command -v "$exe" >/dev/null 2>&1; then
        exec "$exe" "$(dirname "$0")/scripts/build.py" "$@"
    fi
done

echo "Error: Python not found on PATH" >&2
exit 1
