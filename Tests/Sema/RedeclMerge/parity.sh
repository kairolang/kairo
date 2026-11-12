#!/usr/bin/env bash
# Accept/reject parity between kcc and clang over ./parity.
# The .cpp is the ORACLE (OVERLOAD.md: behaviour is 1:1). A divergence is a
# bug in R unless it is listed in kairo-only/README as a deliberate rule.
#
# Runnable from anywhere: paths are derived from this script, not the cwd.
# Usage: parity-verbose.sh [debug|release]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"

# lit now runs these too -- `lit Tests/Sema/RedeclMerge/parity` -- and is the
# path CI should use. This script stays for the verbose per-case output.

mode=debug
if [[ -n "$1" ]]; then mode="$1"; fi

# Do NOT hardcode a triple: a fixed arm64-apple-macosx silently reports
# "no binary" on every other host. KAIRO_BIN wins if set, as in lit.
kcc="$KAIRO_BIN"
if [[ -z "$kcc" ]]; then
    for cand in "$root"/build/*/"$mode"/bin/kairo; do
        if [[ -x "$cand" ]]; then kcc="$cand"; break; fi
    done
fi

if [[ ! -x "$kcc" ]]; then
    echo "no kairo binary found under $root/build/*/$mode/bin/ (set KAIRO_BIN to override)"
    exit 2
fi
echo "kcc: $kcc"

pass=0
fail=0

while IFS= read -r k; do
    cpp="${k%.k}.cpp"
    rel="${k#$here/parity/}"

    if [[ ! -f "$cpp" ]]; then
        echo "NO-ORACLE  $rel"
        ((fail++))
        continue
    fi

    kcc_out=$("$kcc" "$k" --type-check-only 2>&1)
    kv=$?
    clang_out=$(clang -fsyntax-only -std=c++20 "$cpp" 2>&1)
    cv=$?

    kr=reject
    if [[ $kv -eq 0 ]]; then kr=accept; fi
    cr=reject
    if [[ $cv -eq 0 ]]; then cr=accept; fi

    if [[ "$kr" == "$cr" ]]; then
        echo "ok         $kr  $rel"
        ((pass++))
        if [[ -n "$kcc_out" ]]; then
            echo "  kcc output:"
            echo "$kcc_out" | sed 's/^/    /'
        fi
        if [[ -n "$clang_out" ]]; then
            echo "  clang output:"
            echo "$clang_out" | sed 's/^/    /'
        fi
    else
        echo "DIVERGE    kairo=$kr clang=$cr  $rel"
        ((fail++))
        echo "  kcc output (exit $kv):"
        echo "$kcc_out" | sed 's/^/    /'
        echo "  clang output (exit $cv):"
        echo "$clang_out" | sed 's/^/    /'
    fi
done < <(find "$here/parity" -name "*.k" | sort)

echo
echo "$pass ok, $fail diverged"
[[ $fail -eq 0 ]]