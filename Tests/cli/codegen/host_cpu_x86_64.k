// The host CPU default on x86-64: the cc1 line names the highest x86-64
// level the host has (x86-64 itself on a CPU below x86-64-v2) and tunes
// for the host's CPU. --mtune still picks the tuning, --march and --mcpu
// replace the level, and --m32 leaves the host's architecture, so it keeps
// the 32-bit target's own CPU.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: host-x86_64
// RUN: %kairo %s --print-clang-args --mcpu= | %FileCheck %s --check-prefix=LINE
// LINE:      -target-cpu x86-64{{(-v[234])?}} {{.*}}-tune-cpu {{[a-z0-9_.-]+}}
// LINE-NOT:  -tune-cpu

// RUN: %kairo %s --print-target-info --mcpu= | %FileCheck %s --check-prefix=INFO
// INFO:      Host CPU:        x86-64{{(-v[234])?$}}
// INFO-NEXT: Tune CPU:        {{[a-z0-9_.-]+$}}

// RUN: %kairo %s --print-clang-args --mcpu= --mtune=znver2 | %FileCheck %s --check-prefix=TUNE
// TUNE:      -target-cpu x86-64{{(-v[234])?}} {{.*}}-tune-cpu znver2
// TUNE-NOT:  -tune-cpu

// RUN: %kairo %s --print-clang-args --mcpu= --march=x86-64-v2 | %FileCheck %s --check-prefix=MARCH
// MARCH:     -target-cpu x86-64-v2
// MARCH-NOT: -target-cpu
// MARCH-NOT: -tune-cpu

// The portable spellings: --march=x86-64 runs on every x86-64 CPU, and
// --mcpu=baseline is that with clang's generic tuning, the line a --target
// build gets.
// RUN: %kairo %s --print-clang-args --mcpu= --march=x86-64 | %FileCheck %s --check-prefix=PORTABLE
// PORTABLE:     -target-cpu x86-64{{ }}
// PORTABLE-NOT: -target-cpu
// PORTABLE-NOT: -tune-cpu
// RUN: %kairo %s --print-clang-args | %FileCheck %s --check-prefix=BASE
// BASE:      -target-cpu x86-64 -tune-cpu generic
// BASE-NOT:  -target-cpu
// BASE-NOT:  -tune-cpu

// RUN: %kairo %s --print-clang-args --mcpu= --mcpu=znver3 | %FileCheck %s --check-prefix=MCPU
// MCPU:      -target-cpu x86-64 -tune-cpu generic
// MCPU:      -target-cpu znver3 -tune-cpu znver3
// MCPU-NOT:  -target-cpu

// RUN: { %kairo %s --print-target-info --mcpu= --m32 || true; } | %FileCheck %s --check-prefix=M32
// M32-NOT:   Host CPU:
// M32:       Default CPU:
