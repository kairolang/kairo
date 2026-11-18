// Assigning to a `const` binding is a compile error (variables.mdx;
// nullables.mdx, Const interaction: `const x: i32? = 42` then `x = null`
// is an error). Kairo reports it, not the C++ compiler, so
// `--type-check-only` catches it.
//
//
// Both assignments are SC071E from Sema; clang alone would reject them
// only later (CL001E "cannot assign to variable with const-qualified
// type" / "no viable overloaded '='").

fn main() -> i32 {
    const x: i32? = 42
    x = null
// CHECK: const_assign.k:[[@LINE-1]]:5: error [SC071E]: cannot assign to 'x': it is const
    const y: i32 = 1
    y = 2
// CHECK: const_assign.k:[[@LINE-1]]:5: error [SC071E]: cannot assign to 'y': it is const
    return y
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
