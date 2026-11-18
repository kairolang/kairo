// --print-cpus and --print-target-info on a triple LLVM does not know must
// print the P004F error and exit nonzero. The error was built but never
// flushed (info queries exit before execute(), which is what drains the
// engine), so the run failed with no output at all.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-cpus --target=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=CPUS
// RUN: not %kairo %s --print-cpus --target=bogus > /dev/null 2>&1
// CPUS: fatal [P004F]: unknown target triple
// RUN: { %kairo %s --print-target-info --target=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=INFO
// RUN: not %kairo %s --print-target-info --target=bogus > /dev/null 2>&1
// INFO: fatal [P004F]: unknown target triple
