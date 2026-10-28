// CRTP without `unsafe`: inside `class <X derives Mixin<X>> Mixin` the bound
// says every X is a Mixin<X>, so `&self as *const X` is a downcast whose
// target is known statically -- no vtable needed, like C++'s static_cast in
// CRTP (user decision 2026-10-28: allowed when the bound proves the
// relation, lowered to static_cast; every other unrelated pointer cast
// stays SC091E, Tests/Sema/ExprTyper/crtp_cast_errors.k).
//
// `s.self_ptr()` is a member of Seven's generic BASE, so its result reads
// through the base instance Mixin<Seven> (X := Seven): `->v` binds.
// crtp_cast_bound.k and crtp_cast_duck.k cover the wider shapes.

class <X derives Mixin<X>> Mixin {
    fn self_ptr(const self) -> *const X { return &self as *const X }
}

class Seven derives Mixin<Seven> {
    pub var v: i32
    fn Seven(self) { self.v = 7 }
}

fn main() -> i32 {
    var s = Seven()
    return s.self_ptr()->v
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
