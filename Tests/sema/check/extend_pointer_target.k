// A pointer type cannot be extended. A pointer's
// members are its pointee's, reached with `->`; before this error the
// block passed Sema and the compiler stopped with an internal error in
// CXXSpell::ext_scope_name. A container OF pointers stays an ordinary
// target (line 9).

extend <T> unsafe *T { pub fn a(self) -> i32 { return 1 } }
extend <T> *T { pub fn b(self) -> i32 { return 1 } }
extend <T> [*T] { pub fn c(self) -> i32 { return 1 } }
extend <T> *const T { pub fn d(self) -> i32 { return 1 } }
extend *i32 { pub fn e(self) -> i32 { return 1 } }

fn main() -> i32 {
    var x = 1
    var v: [*i32] = [&x]
    return v.c() - 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: extend_pointer_target.k:7:19: error [SC282E]: a pointer type cannot be extended; extend the type it points to, and call those members through the pointer with '->'
// CHECK: extend_pointer_target.k:8:12: error [SC282E]: a pointer type cannot be extended
// CHECK: extend_pointer_target.k:10:12: error [SC282E]: a pointer type cannot be extended
// CHECK: extend_pointer_target.k:11:8: error [SC282E]: a pointer type cannot be extended
