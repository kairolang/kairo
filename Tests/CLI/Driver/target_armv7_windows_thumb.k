// An `armv7-windows-gnu` target is compiled as `thumbv7`: Windows on ARM is
// Thumb-2 only, and an ARM-mode triple reaches LLVM's CodeView writer, which
// has no CPU type for it and aborts.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-armv7-windows-gnu
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --target armv7-windows-gnu --print-clang-args 2>&1 | %FileCheck %s --check-prefix=ARGS
// ARGS: -triple thumbv7-{{.*}}windows-gnu
// ARGS-NOT: -triple armv7
// RUN: %kairo %s --target armv7-windows-gnu -c --debug-info -o %t.d/m.o --cache-dir %t.d/c 2>&1 | %FileCheck %s --check-prefix=NOCRASH --allow-empty
// NOCRASH-NOT: LLVM ERROR
// NOCRASH-NOT: CodeView
// RUN: test -s %t.d/m.o
