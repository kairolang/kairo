// A `thread` variable is a thread-local declaration, not the `thread`
// expression: it compiles and runs, and a plain call is unaffected.

fn work() -> i32 { return 1 }

thread counter: i32 = 0

fn main() -> i32 {
    counter += work()
    counter += 1
    return counter - 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='error [' --implicit-check-not='I003E'
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
