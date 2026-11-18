// A slice literal at namespace scope (a file-scope `var`, a `const`, a
// variable in a `module` block) checks its elements against the declared
// element type: a string or a lossy float element is SC028E, and the
// well-typed slice beside them is accepted.

var top: [i32;] = [1, 2, 3]

module m {
    pub var inner: [i32;] = [7, "x", 9]
}

const fixed: [i32;] = [10, 2.5]

fn main() -> i32 { return top[0] }

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: namespace_scope_reject.k:9:33: error [SC028E]: cannot convert 'string' to 'i32'
// CHECK: namespace_scope_reject.k:12:28: error [SC028E]: cannot convert 'f64' to 'i32'; the conversion may lose value and needs an explicit 'as'
