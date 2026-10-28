// The sibling rule is per branch: a repeat inside ONE branch of a deferred
// `eval if` is the redefinition it would be anywhere else, and the sibling
// branch's declaration of the same name is not reported with it.
struct Plain { var x: i32 }

class Twice {
    eval if is_trivially_copyable!(Plain) {
        var c: i32
        var c: i32
    } else {
        var c: i64
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: late_fold_siblings_same_branch.k:9:{{[0-9]+}}: error [R029E]: 'c' redefined
// CHECK-NEXT: late_fold_siblings_same_branch.k:8:{{[0-9]+}}: note [R029N]: previous declaration of 'c' is here
