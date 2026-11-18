// --edition accepts 2025 and 2026 (the default) and rejects anything else
// with the usual invalid-value error. --borrow-check takes warn|error|off and
// --amt-mode takes warn|error|silent; a bogus value is rejected the same way
// instead of being stored. None of these flags changes behaviour yet beyond
// the check on the value.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only --edition=2025 %s
// RUN: %kairo --type-check-only --edition 2026 %s
// RUN: { %kairo --type-check-only --edition=2024 %s 2>&1 || true; } 2>&1 | %FileCheck %s --check-prefix=ED
// ED: error [U003E]: invalid value '2024' for flag '--edition'; accepted: 2025, 2026

// RUN: %kairo --type-check-only --borrow-check=off %s
// RUN: { %kairo --type-check-only --borrow-check=maybe %s 2>&1 || true; } 2>&1 | %FileCheck %s --check-prefix=BC
// BC: error [U003E]: invalid value 'maybe' for flag '--borrow-check'; accepted: warn, error, off

// RUN: %kairo --type-check-only --amt-mode=silent %s
// RUN: { %kairo --type-check-only --amt-mode=loud %s 2>&1 || true; } 2>&1 | %FileCheck %s --check-prefix=AM
// AM: error [U003E]: invalid value 'loud' for flag '--amt-mode'; accepted: warn, error, silent
