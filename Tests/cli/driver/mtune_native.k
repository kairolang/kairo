// `--mtune native` tunes for the host's CPU, as clang's -mtune=native does.
// cc1's -tune-cpu has no `native`, so kairo resolves the word to the host
// CPU's name before anything forwards it, as it does for --mcpu native, and
// the caches key the name it resolved to.
// Tuning changes no result, so a --target build for the host's own
// architecture takes it too (32-bit x86 included); a target of another
// architecture has no CPU of that name, and that is P006E.

fn main() -> i32 {
    return 7
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: host-x86_64, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --mtune native -o %t.d/a.out --cache-dir %t.d/c
// RUN: %t.d/a.out; test $? -eq 7

// RUN: %kairo %s --print-clang-args --mtune=native | %FileCheck %s --check-prefix=LINE
// RUN: %kairo %s --print-clang-args --mtune=native --target=x86_64-linux-musl | %FileCheck %s --check-prefix=LINE
// RUN: %kairo %s --print-clang-args --mtune=native --m32 | %FileCheck %s --check-prefix=LINE
// LINE-NOT: -tune-cpu native
// LINE:     -tune-cpu {{[a-z0-9_.-]+}}
// LINE-NOT: -tune-cpu native

// The host CPU default tunes for the same CPU.
// RUN: %kairo %s --print-target-info --mcpu= --mtune=native > %t.d/native.txt
// RUN: %kairo %s --print-target-info --mcpu= > %t.d/host.txt
// RUN: cmp %t.d/native.txt %t.d/host.txt

// RUN: { %kairo %s --mtune native --target aarch64-unknown-linux-gnu --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=CROSS
// CROSS: error [P006E]: '--mtune native' names the host CPU, which is no CPU of target 'aarch64-unknown-linux-gnu'
// CROSS: note [P006N]: name the CPU explicitly; run with --print-cpus --target=aarch64-unknown-linux-gnu to list valid values
// CROSS-NOT: I006F

// Incremental Sema keys the CPU the word resolved to: the command line
// spells only `native`, which names another CPU on another machine.
// RUN: cd %t.d && %kairo -I %S/../../sema/incremental/inputs/records %S/../../sema/incremental/inputs/records/main.k --type-check-only --cache-dir base --incremental-sema
// RUN: cd %t.d && %kairo -I %S/../../sema/incremental/inputs/records %S/../../sema/incremental/inputs/records/main.k --type-check-only --cache-dir tune --incremental-sema --mtune=native
// RUN: grep -h '^f\.cpu [0-9a-f]' %t.d/base/*/mod/run-*.txt > %t.d/base.cpu
// RUN: grep -h '^f\.cpu [0-9a-f]' %t.d/tune/*/mod/run-*.txt > %t.d/tune.cpu
// RUN: not cmp -s %t.d/base.cpu %t.d/tune.cpu

// kcc passes -mtune=native as clang does.
// REQUIRES: kcc
// RUN: cd %t.d && %kcc -### -c %s -mtune=native > %t.d/kcc.txt 2>&1
// RUN: not grep -e '-tune-cpu native' -e 'unknown target CPU' %t.d/kcc.txt
// RUN: grep -q -e '-tune-cpu ' %t.d/kcc.txt
