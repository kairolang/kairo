// The type-fact intrinsics (EVAL.md 4.2b): a bool C++ computes with the
// clang builtin of the same name. In a function body an `eval if` on one
// of a concrete type is decided by Sema, and the taken branch is kept after
// a static assertion of the condition, which clang checks.
struct Plain { var x: i32 }

fn main() -> i32 {
    var a = is_trivially_copyable!(Plain)
    var b = is_trivially_destructible!([i32; 4])
    eval if is_trivially_copyable!(Plain) {
        if a && b { return 0 }
    }
    return 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: TypeTraitExpr is_trivially_copyable! Plain
// AST: TypeTraitExpr is_trivially_destructible! [i32; 4]
// AST: TypeTraitExpr is_trivially_copyable! Plain

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: static_assert{{ ?}}(__is_trivially_copyable(

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
