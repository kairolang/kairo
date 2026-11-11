// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// An unknown string-literal suffix is a diagnostic, never silently dropped.
// CHECK: string_literal_suffix_unknown.k:[[#]]:[[#]]: error [SC074E]: unknown literal suffix '_nope'
fn main() -> i32 {
    var n = "hello"_nope
    return 0
}
