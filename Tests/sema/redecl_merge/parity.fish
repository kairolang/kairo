#!/usr/bin/env fish
# Accept/reject parity between kairo and clang over ./parity.
# The .cpp is the ORACLE (OVERLOAD.md: behaviour is 1:1). A divergence is a
# bug in R unless it is listed in kairo-only/README as a deliberate rule.
#
# Runnable from anywhere: paths are derived from this script, not the cwd.
# Usage: parity.fish [debug|release]

set -l here (realpath (dirname (status filename)))
set -l root (realpath $here/../../..)

set -l mode debug
if set -q argv[1]; set mode $argv[1]; end
# Do not hardcode a triple (a fixed one reports "no binary" on every host
# but one). KAIRO_BIN wins if set, as it does in lit.
set -l kairo $KAIRO_BIN
if test -z "$kairo"
    for cand in $root/build/*/$mode/bin/kairo
        if test -x $cand
            set kairo $cand
            break
        end
    end
end

if not test -x $kairo
    echo "no binary at $kairo"; exit 2
end

set -l pass 0
set -l fail 0

for k in (find $here/parity -name "*.k" | sort)
    set -l cpp (string replace -r "\.k\$" .cpp $k)
    set -l rel (string replace $here/parity/ "" $k)

    if not test -f $cpp
        echo "NO-ORACLE  $rel"
        set fail (math $fail + 1)
        continue
    end

    $kairo $k --type-check-only >/dev/null 2>&1
    set -l kv $status
    clang -fsyntax-only -std=c++20 $cpp >/dev/null 2>&1
    set -l cv $status

    set -l kr reject; test $kv -eq 0; and set kr accept
    set -l cr reject; test $cv -eq 0; and set cr accept

    if test $kr = $cr
        echo "ok         $kr  $rel"
        set pass (math $pass + 1)
    else
        echo "DIVERGE    kairo=$kr clang=$cr  $rel"
        set fail (math $fail + 1)
    end
end

echo
echo "$pass ok, $fail diverged"
test $fail -eq 0
