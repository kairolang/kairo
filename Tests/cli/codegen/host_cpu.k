// A build for the machine it runs on targets that machine's CPU: with no
// --target, --march or --mcpu the CPU is the host's (its x86-64 level, or
// what -mcpu=native gives on arm64), and --print-target-info names it
// `Host CPU`. `--mcpu=baseline` keeps the target's own default CPU, and so
// does every --target build, also one that names the host's own triple: the
// host says nothing about the machine a --target build is for. An explicit
// --march or --mcpu replaces the host's CPU.
//
// %kairo carries --mcpu=baseline, so the suite never depends on the machine
// it runs on; `--mcpu=` (empty, the flag as if not given) takes it back off.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: host-x86_64 || host-aarch64
// RUN: %kairo %s --print-target-info --mcpu= | %FileCheck %s --check-prefix=HOST
// HOST:     Host CPU:        {{[^ ]+$}}
// HOST-NOT: Default CPU:

// RUN: %kairo %s --print-target-info | %FileCheck %s --check-prefix=BASE
// RUN: %kairo %s --print-target-info --mcpu= --mcpu=baseline | %FileCheck %s --check-prefix=BASE
// RUN: %kairo %s --print-target-info --mcpu= --mcpu baseline | %FileCheck %s --check-prefix=BASE
// BASE-NOT: Host CPU:
// BASE-NOT: Tune CPU:
// BASE:     Default CPU:     {{[^ ]+$}}
// BASE-NOT: Host CPU:
// BASE-NOT: Tune CPU:

// The word never reaches clang as a CPU name.
// RUN: %kairo %s --print-clang-args --mcpu= --mcpu=baseline | %FileCheck %s --check-prefix=WORD
// WORD-NOT: baseline

// RUN: { %kairo %s --print-target-info --mcpu= --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=CROSS
// CROSS-NOT: Host CPU:
// CROSS:     Default CPU:     {{[^ ]+$}}

// `baseline` is accepted with --target, where it changes nothing.
// RUN: { %kairo %s --print-target-info --target=x86_64-linux-musl || true; } > %t.a
// RUN: { %kairo %s --print-target-info --mcpu= --target=x86_64-linux-musl || true; } > %t.b
// RUN: cmp %t.a %t.b
