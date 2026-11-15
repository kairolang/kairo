// A full function specialization must specialize exactly one primary
// template in its scope, with the primary's signature at its arguments
// ([temp.expl.spec]; clang rejects each of these). Each is one error at the
// specialization's name, with a note at the primary it was compared with.

fn <> lone<i32>() -> i32 { return 2 }

fn <T> r() -> i32 { return 1 }
fn <> r<i32>() -> bool { return true }

fn <T> w(x: T) -> i32 { return 1 }
fn <> w<i32>(x: u8) -> i32 { return 2 }

fn <T, U> v() -> i32 { return 1 }
fn <> v<i32>() -> i32 { return 2 }

fn <T> d() -> i32 { return 1 }
fn <> d<i32>() -> i32 { return 2 }
fn <> d<i32>() -> i32 { return 3 }

class <T> G {
    fn <U> m(self) -> i32 { return 1 }
    fn <> m<i32>(self) -> i32 { return 2 }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: fn_spec_mismatch.k:6:{{[0-9]+}}: error [R042E]: 'lone' is declared as a specialization, but no primary template named 'lone' is visible here
// CHECK: fn_spec_mismatch.k:9:{{[0-9]+}}: error [SC330E]: explicit specialization of 'r' differs from its primary template in its return type
// CHECK: fn_spec_mismatch.k:8:{{[0-9]+}}: note [SC330N]: primary template is here
// CHECK: fn_spec_mismatch.k:12:{{[0-9]+}}: error [SC330E]: explicit specialization of 'w' matches no primary template
// CHECK: fn_spec_mismatch.k:11:{{[0-9]+}}: note [SC330N]: primary template is here
// CHECK: fn_spec_mismatch.k:15:{{[0-9]+}}: error [SC330E]: explicit specialization of 'v' matches no primary template
// CHECK: fn_spec_mismatch.k:19:{{[0-9]+}}: error [R029E]: redefinition of 'd'
// CHECK: fn_spec_mismatch.k:23:{{[0-9]+}}: error [SC116E]: an explicit specialization of 'm' inside a generic type or extension is not supported; specialize a method of a generic class in an extension of it
// CHECK-NOT: error
