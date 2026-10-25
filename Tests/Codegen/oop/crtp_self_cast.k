// CRTP without `unsafe`: inside `class <X derives Mixin<X>> Mixin` the bound
// says every X is a Mixin<X>, so `&self as *const X` is a downcast whose
// target is known statically -- no vtable needed, like C++'s static_cast in
// CRTP.
//
// XFAIL: *
// Waiting on Sema using the `derives` bound to relate X to Self: today the
// cast is SC091E "pointer cast between unrelated types '*const Mixin<X>' and
// '*const X'". Whether this should be allowed safely at all is a language
// decision (casting.md requires a vtable for every downcast); if it is
// refused by design, turn this into a diagnostic test instead.
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

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
