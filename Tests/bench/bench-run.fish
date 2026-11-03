#!/usr/bin/env fish
# Builds every benchmark in every language at -O3, then times them
# interleaved and checks the outputs agree.
#
#   ./bench-run.fish [--smoke] [runs] [bench ...]   runs defaults to 5; no names = all
#   ./bench-run.fish 3 nbody gsort
#   ./bench-run.fish --smoke 1                      quick check that everything builds and agrees
#
# Tools: KAIRO, KCC, CXX_CLANG, CXX_GCC, RUSTC override the defaults. A
# missing tool skips its column. Binaries go to ./bin.
set -l runs 5
set -l only
set -l smoke
if contains -- --smoke $argv
    set smoke --smoke
    set -e argv[(contains -i -- --smoke $argv)]
end
if test (count $argv) -gt 0
    if string match -qr '^[0-9]+$' -- $argv[1]
        set runs $argv[1]
        set only $argv[2..-1]
    else
        set only $argv
    end
end
set -q KAIRO;     or set KAIRO ../../build/x86_64-linux-gnu/debug/bin/kairo
set -q KCC;       or set KCC ../../build/x86_64-linux-gnu/debug/bin/kcc
set -q CXX_CLANG; or set CXX_CLANG clang++
set -q CXX_GCC;   or set CXX_GCC g++
set -q RUSTC;     or set RUSTC rustc
mkdir -p bin

set -l benches nbody btree fannkuch gsort gen errpath alloc interp closures dispatch wideint fmt spectral slices nullable scopes
if test (count $only) -gt 0
    set benches $only
end

for b in $benches
    if test -f $b.k
        $KAIRO $b.k -I . -O3 -o bin/$b.kairo >/dev/null 2>&1; or echo "kairo build failed: $b"
    end
    if test -f $b.rs; and command -q $RUSTC
        $RUSTC -C opt-level=3 -C codegen-units=1 -o bin/$b.rust $b.rs 2>/dev/null; or echo "rust build failed: $b"
    end
    if test -f $b.cc
        for cxx in clang:$CXX_CLANG gcc:$CXX_GCC kcc:$KCC
            set -l tag (string split -m1 : $cxx)[1]
            set -l exe (string split -m1 : $cxx)[2]
            command -q $exe; or continue
            if test $b = alloc
                $exe -O3 -std=c++20 $b.cc -o bin/$b.$tag-new >/dev/null 2>&1
                $exe -O3 -std=c++20 -DUSE_MALLOC $b.cc -o bin/$b.$tag-malloc >/dev/null 2>&1
            else
                $exe -O3 -std=c++20 $b.cc -o bin/$b.$tag >/dev/null 2>&1; or echo "$tag build failed: $b"
            end
        end
    end
end

python3 bench-timing.py $smoke $runs $benches