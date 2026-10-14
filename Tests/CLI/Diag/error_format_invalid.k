// --error-format accepts pretty, basic and json. msvc was advertised but fell
// through to pretty; it is now refused, and so is any unknown value.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --error-format=msvc 2>&1 || true; } | %FileCheck %s --check-prefix=MSVC
// RUN: { %kairo %s --type-check-only --error-format=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BOGUS
// MSVC: error [U001E]: error format 'msvc' is not implemented
// BOGUS: error [U001E]: unknown error format 'bogus' (expected pretty, basic or json)
