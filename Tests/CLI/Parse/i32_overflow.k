// An integer too large for i32 is "out of range", not "expects an integer":
// the digits are fine, so telling the user to look for a typo is wrong.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --heap-size=99999999999 2>&1 || true; } | %FileCheck %s --check-prefix=OVF
// OVF: error [U003E]: flag '--heap-size' value '99999999999' is out of range for a 32-bit integer
// RUN: { %kairo %s --type-check-only --heap-size=abc 2>&1 || true; } | %FileCheck %s --check-prefix=NAN
// NAN: error [U003E]: flag '--heap-size' expects an integer, got 'abc'
