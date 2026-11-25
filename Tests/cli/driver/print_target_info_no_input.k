// --print-target-info needs no input file and prints what a compile with
// the same flags uses: the CPU line matches the one printed with an input,
// for the host CPU default, --mcpu, --mcpu native and --march alike.
// Without the query, no input is still an error.

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo --print-target-info --target=x86_64-linux-gnu --mcpu=znver3 | %FileCheck %s --check-prefix=MCPU
// MCPU-NOT: Default CPU
// MCPU:     CPU:             znver3
// RUN: %kairo --print-target-info --target=x86_64-linux-gnu | %FileCheck %s --check-prefix=DEFAULT
// DEFAULT: Default CPU:     x86-64{{$}}
// RUN: %kairo --print-target-info --target=x86_64-linux-gnu --march=haswell | %FileCheck %s --check-prefix=MARCH
// MARCH: CPU:     haswell{{$}}

// The host's CPU, with and without an input.
// RUN: %kairo --print-target-info --mcpu= > %t.d/host.none
// RUN: %kairo %s --print-target-info --mcpu= > %t.d/host.input
// RUN: cmp %t.d/host.none %t.d/host.input
// RUN: %kairo --print-target-info --mcpu=native > %t.d/native.none
// RUN: %kairo %s --print-target-info --mcpu=native > %t.d/native.input
// RUN: cmp %t.d/native.none %t.d/native.input
// RUN: %kairo --print-target-info > %t.d/base.none
// RUN: %kairo %s --print-target-info > %t.d/base.input
// RUN: cmp %t.d/base.none %t.d/base.input

// RUN: { %kairo 2>&1 || true; } | %FileCheck %s --check-prefix=NOINPUT
// RUN: not %kairo > /dev/null 2>&1
// RUN: { %kairo --print-clang-args 2>&1 || true; } | %FileCheck %s --check-prefix=NOINPUT
// NOINPUT: error [U004E]: no input files
