// A dead `eval if` branch in a function body is dead text too: a macro it
// invokes is not expanded and a `compile_error!` in it does not fire, so a
// branch may name a macro that exists on another configuration only.

macro ON!() { 1 }

fn chosen() -> i32 {
    eval if defined!(ON) {
        return 5
    } else {
        compile_error!("a dead function-body branch was expanded")
        return 0
    }
}

fn skipped() -> i32 {
    eval if !defined!(ON) {
        return never_defined_macro!(1, 2)
    }
    return 6
}

fn main() -> i32 {
    return chosen() + skipped() - 11
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.e
// RUN: %t.o2.exe
