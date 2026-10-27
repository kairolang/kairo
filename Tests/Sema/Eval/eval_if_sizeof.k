eval if sizeof usize < 8 {
    fn narrow() -> i32 { return 1 }
}

class <T> Box { pub var v: T }

fn pick() -> i32 {
    eval if sizeof usize < 8 { return 32 }
    return 64
}

fn main() -> i32 {
    var small = sizeof usize < 8              // `usize`, then a comparison
    var boxed = sizeof Box<i32> == 4          // still generic arguments
    if small || (!boxed) { return 1 }
    return pick()
}

// EVAL.md 4.2b. A declaration-scope `eval if` folds before types are
// resolved, so `sizeof` does not fold there: an error that names the two
// forms that work. In a function body the same condition is `if constexpr`.
// And `sizeof usize < 8` parses as `(sizeof usize) < 8`: a builtin
// primitive takes no generic arguments, so its `<` compares.
// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: eval_if_sizeof.k:1:9: error [SC001E]: the condition of an 'eval if' outside a function body must fold before names are resolved; 'sizeof' needs a type's layout, which is not known before types are resolved
// CHECK-NEXT: eval_if_sizeof.k:1:9: note [SC001N]: for the pointer width, test the target instead: 'defined!(__LP64__)'; or move the 'eval if' into a function body, where it is 'if constexpr' and sees layouts
