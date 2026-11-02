#!/usr/bin/env fish
# Builds every variant at -O3 and times them, interleaved.
# Usage: ./run.fish [runs]      (env: KAIRO, KCC, CXX_CLANG, CXX_GCC override tools)
set -l runs (test (count $argv) -gt 0; and echo $argv[1]; or echo 5)
set -q KAIRO;     or set KAIRO ../build/x86_64-linux-gnu/debug/bin/kairo
set -q KCC;       or set KCC kcc
set -q CXX_CLANG; or set CXX_CLANG clang++
set -q CXX_GCC;   or set CXX_GCC g++
mkdir -p bin

for b in nbody btree fannkuch
    $KAIRO $b.k -I . -O3 -o bin/{$b}_kairo; or echo "kairo build failed: $b"
    rustc -C opt-level=3 -C codegen-units=1 -o bin/{$b}_rust rs/$b.rs 2>/dev/null; or echo "rust build failed: $b"
    if command -q $CXX_CLANG
        $CXX_CLANG -O3 -std=c++20 $b.cc -o bin/{$b}_clang
    end
    if command -q $CXX_GCC
        $CXX_GCC -O3 -std=c++20 $b.cc -o bin/{$b}_gcc
    end
    if command -q $KCC
        $KCC -O3 -std=c++20 $b.cc -o bin/{$b}_kcc 2>/dev/null
    end
end

python3 timing.py $runs
