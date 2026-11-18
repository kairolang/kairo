// A lone `}` in an f-string is the syntax error S016E ("unmatched '}' in format string literal"); the fix is `\}`.
// Rules asserted (`kairo --explain S016E`: in a format string `{` opens an interpolation and `}` closes it, a lone `}`
// is invalid; website language/primitives.mdx, Strings: `\}` is the literal brace).
// Cases from Rust library/coretests/tests/fmt/mod.rs (unbalanced braces are rejected at compile time)

fn main() -> i32 {
    var s = f"a}b"
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: { %kairo_new %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: :7:{{[0-9]+}}: error [S016E]
