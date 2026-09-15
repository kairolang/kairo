ffi "c++" import "modes.hh";

fn S::f(self, @inout x: i32) { x = x + 1; }       // expect: clean -- ONE entity with S::f(int&) (dump: redecl chain x2 under S::f)
fn S::g(self, const x: i32) { }                   // expect: clean -- one entity with S::g(const int&)
fn S::h(self, @move x: i32) { }                   // expect: clean -- one entity with S::h(int&&)
fn S::b(self, @inout x: i32) { }                  // expect: clean -- pairs with b(int&), NOT b(const int&)
fn S::b(self, x: i32) { }                         // expect: clean -- pairs with b(const int&)
fn S::f(self, x: i32) { }                         // expect: error out-of-line definition does not match any declaration (by-value != int&)

fn main() {
    var n = 1;
    var s = S();
    s.f(&n);                                      // expect: clean
    s.b(&n);                                      // expect: clean, resolves to b(int&)
    const c = 2;
    s.b(c);                                       // expect: clean, resolves to b(const int&)
    free_f(n);                                    // expect: clean
}

// --- lit wiring -----------------------------------------------------------
// Against a FOREIGN decl the C++ reference kind is read as the mode it
// spells (RedeclMerge::_param_shape): `T&` is `@inout`, `const T&` by value,
// `T&&` `@move`. At the CALL an imported signature keeps C++ semantics: the
// marker is a Kairo-declared-parameter thing, so `free_f(int&)` takes `n`,
// and `&n` there would be address-of (`*i32`) and not bind.
//
// Not a %parity case despite the directory: @inout / @move have no C++
// spelling, so there is no oracle to write.
//
// The second RUN pins that N attached every definition to S -- the
// out-of-line name lookup goes through MemberLookup::in_scope, so a Kairo
// name is re-keyed into the header TU's imm space rather than probing S's
// table with this TU's index. Which `b` overload each `s.b(...)` call picks is
// not observable in the dump (both return void, and the line-8 error stops
// sema before Checked); the pairing is proven by the absence of R031E on
// lines 3-7.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// SEMA:      -- out-of-line definitions --
// SEMA-NEXT: f @ 3:1 -> attached to S
// SEMA-NEXT: g @ 4:1 -> attached to S
// SEMA-NEXT: h @ 5:1 -> attached to S
// SEMA-NEXT: b @ 6:1 -> attached to S
// SEMA-NEXT: b @ 7:1 -> attached to S
// SEMA-NEXT: f @ 8:1 -> attached to S
//
// DIAG-NOT: modes.k:{{[1-7]}}:{{[0-9]+}}: error
// DIAG:     modes.k:8:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG-NOT: error [
