class A {
    var n: i32
    fn A(self, @move other: Self) { }           // expect: error transfer-ctor-spelling
}
class B {
    var n: i32
    fn B(self, @inout other: Self) { }          // expect: error transfer-ctor-spelling
}
class C {
    var n: i32
    fn C(self, other: Self) { }                 // expect: error transfer-ctor-spelling
}
class D {
    var n: i32
    fn D(self, other: Self, k: i32 = 0) { }     // expect: error transfer-ctor-spelling
}
class E {
    var n: i32
    @move fn E(self, @move other: Self) { }     // expect: error marked-transfer-param-bare
}
class F {
    var n: i32
    @move fn F(self, const other: Self) { }     // expect: error move-from-const
}
// expect: no other diagnostics

// --- lit wiring -----------------------------------------------------------
// Every constructor C++ would read as a copy or move constructor, declared
// any way but `@copy fn` / `@move fn` with a bare `other: Self`, is rejected
// in Kairo at the declaration -- before clang ever sees a by-value copy
// constructor, which is what the CL001E line asserts.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:     transfer_ctor_err.k:3:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     transfer_ctor_err.k:7:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     transfer_ctor_err.k:11:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     transfer_ctor_err.k:15:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     transfer_ctor_err.k:19:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     transfer_ctor_err.k:23:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG-NOT: {{error|warning}} [
// DIAG-NOT: CL001E
