// Assigning to a `const` binding is a compile error (variables.mdx;
// nullables.mdx, Const interaction: `const x: i32? = 42` then `x = null`
// is an error). Kairo reports it, not the C++ compiler, so
// `--type-check-only` catches it.
//
// XFAIL: *
// Ticket "[Sema] Assigning to a `const` local is not diagnosed by Sema"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today both assignments pass
// --type-check-only; a full build fails in clang (CL001E "cannot assign to
// variable with const-qualified type" / "no viable overloaded '='").
// ConstChecking is a TODO in Sema.k. The code is not decided; the checks
// ask for an error at each assignment. When it XPASSes, delete the XFAIL
// and pin the code and message.

fn main() -> i32 {
    const x: i32? = 42
    x = null
// CHECK: const_assign.k:[[@LINE-1]]:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
    const y: i32 = 1
    y = 2
// CHECK: const_assign.k:[[@LINE-1]]:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
    return y
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
