// Copying a Kairo class whose `@copy` is `= delete` was caught only by
// clang at codegen (CL001E "call to deleted constructor"). It is
// SC182E at the copy, with a note at the deleted constructor, as the
// same copy of an imported C++ record already was. A prvalue is not a copy
// (elided), a `const` parameter binds without one, and assigning such a
// value stays the one SC071E.

class NoCopy {
    pub var v: i32
    pub fn NoCopy(self, v: i32) { self.v = v }
    @copy fn NoCopy(self, const other: Self) = delete
}

fn take(n: NoCopy) -> i32 { return n.v }
fn peek(const n: NoCopy) -> i32 { return n.v }

fn main() -> i32 {
    var a = NoCopy(1)
    var b = a
    var c = take(a)
    var d = peek(a)
    var e = NoCopy(2)
    return b.v + c + d + e.v
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: copy_deleted_kairo_class.k:19:13: error [SC182E]: cannot copy a value of type 'NoCopy': its copy constructor is deleted
// DIAG-NEXT: copy_deleted_kairo_class.k:11:11: note [I900N]: the copy constructor is deleted here
// DIAG-NEXT: copy_deleted_kairo_class.k:20:18: error [SC182E]: cannot copy a value of type 'NoCopy': its copy constructor is deleted
// DIAG-NEXT: copy_deleted_kairo_class.k:11:11: note [I900N]: the copy constructor is deleted here
// DIAG-NOT: error
