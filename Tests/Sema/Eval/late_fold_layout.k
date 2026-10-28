// The late fold reads only the layouts Sema predicts (EVAL.md 4.2b):
// builtins, pointers, arrays, and plain enums and records of them. A
// derived class is laid out by C++, so a declaration-scope condition cannot
// read its size; in a function body it could.
class Base { var a: i32 }
class Big derives Base { var b: i32 }

eval if sizeof Big > 8 {
    fn big() -> i32 { return 1 }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: late_fold_layout.k:8:9: error [SC001E]: the condition of an 'eval if' outside a function body must fold once types are resolved; the layout of '{{.*}}Big' is C++'s to choose: a declaration-scope condition reads only the layout of builtins, pointers, arrays, and plain enums and records of them
// CHECK-NEXT: late_fold_layout.k:8:9: note [SC001N]: in a function body the same condition is 'if constexpr', which C++ decides with the layout it chooses
