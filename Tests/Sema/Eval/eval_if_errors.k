// Outside a function body an `eval if` decides which declarations exist,
// so its condition must fold before names are resolved (EVAL.md §4.2): a
// call is C++'s to compute, a variable or a `const` is not an eval
// constant (a `const` gets a fix-it to `eval`), and a bool does not compare
// with an integer. A class branch's `var` becomes a field, which declares
// its type; a module or class branch holds declarations only. A condition
// may read an eval constant an earlier `eval if` hoisted.
eval fn decide() -> bool { return true }
var runtime = 3
const C = 1

eval if decide() { fn a() {} }
eval if runtime > 2 { fn b() {} }
eval if C == 1 { fn c() {} }
eval if 1 == true { fn d() {} }

class K {
    eval if true { var untyped = 3 }
}

module m {
    eval if true { 1 + 2 }
}

eval if true { eval X = 1 } else { eval X = 2 }
eval if X == 1 { eval Y = 1 }

fn main() -> i32 { return Y }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: eval_if_errors.k:12:9: error [SC001E]: the condition of an 'eval if' outside a function body must fold before names are resolved; a call is computed by C++ after names are resolved; use an 'eval' constant, a literal or 'defined!' here
// CHECK: eval_if_errors.k:13:9: error [SC001E]: {{.*}}; 'runtime' is not an 'eval' constant
// CHECK-NEXT: eval_if_errors.k:9:5: note [SC001N]: 'runtime' is declared here
// CHECK: eval_if_errors.k:14:9: error [SC001E]: {{.*}}; 'C' is not an 'eval' constant
// CHECK-NEXT: fix-it:{{.*}}:{10:1-10:6}:"eval"
// CHECK-NEXT: eval_if_errors.k:10:7: note [SC001N]: 'C' is declared here
// CHECK: eval_if_errors.k:15:9: error [SC001E]: {{.*}}; it compares a bool with an integer
// CHECK: eval_if_errors.k:18:24: error [SC001E]: a field declares its type; 'untyped' has none
// CHECK: eval_if_errors.k:22:20: error [SC001E]: an 'eval if' in a module or class body holds declarations only
