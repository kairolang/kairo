import self::user

fn main() -> i32 {
    return user::run() - 1
}

// --- lit wiring -----------------------------------------------------------
// std::copy where the `copy` that would implement `CopiesItself` is a
// `prot` member of another module: Kairo does not count it, but C++, which
// has no module access, sees it public. The call is an error naming the
// member, not "ambiguous".
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: user.k:6:13: error [SC162E]: cannot choose an overload here: 'Pt' has a 'copy' that would implement 'CopiesItself', but it is not public
// CHECK: shapes.k:9:8: note [I900N]: 'copy' is declared here
