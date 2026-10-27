// A generic value argument must be eval-able (EVAL.md 3): a `const` is not
// (fix-it to `eval`); a value parameter takes a value and a type parameter
// a type; an array length or argument computed from a value parameter has
// no canonical yet (SC116E).
const NOT_EVAL = 2

class <eval N: usize, T> Ring {
    pub var items: [T; N]
    fn bad(const self) -> [i32; N + 1] { return self.items }
}

fn main() -> i32 {
    var a = Ring<NOT_EVAL, i32>()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: value_generic_errors.k:9:33: error [SC116E]: an array length computed from a generic value parameter is not yet supported; use the parameter itself
// CHECK: value_generic_errors.k:13:18: error [SC001E]: a generic value argument must be an 'eval' constant; 'NOT_EVAL' is 'const', which is not evaluated at compile time
// CHECK-NEXT: fix-it:{{.*}}:{5:1-5:6}:"eval"
// CHECK-NEXT: value_generic_errors.k:5:7: note [SC001N]: 'NOT_EVAL' is declared 'const' here

// A second compile, for the kinds: X runs only once T succeeds.
// RUN: sed -e '/NOT_EVAL, i32/d' -e '/fn bad/d' %s > %t.k
// RUN: echo 'fn kinds() { var x = Ring<i32, i32>()  var y = Ring<4, 5>() }' >> %t.k
// RUN: { %kairo %t.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=KIND
// KIND: error [R001E]: 'N' is a generic value parameter; it takes a compile-time value, not a type
// KIND: note [R001N]: 'N' is declared here
// KIND: error [R001E]: 'T' is a type parameter; it takes a type, not a value
// KIND: note [R001N]: 'T' is declared here
