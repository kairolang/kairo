import lib::*

// EVAL.md §11 (USER): an array length or generic value argument C++
// computes from an eval fn or an eval binding is accepted in a
// declaration's type -- a field, a signature, a namespace-scope binding --
// not only in a function body. EmitPlan defines what such a type names
// (the eval fns, eval constructors and eval bindings, and everything they
// read, transitively through eval fn bodies) ahead of the records and
// signatures using it, each after the records its own body needs complete.

eval fn quad(x: usize) -> usize { return twice(twice(x)) }   // reads lib's twice
eval HALF = twice(2)                     // an eval binding C++ computes
eval FROM_FN = through()                 // reads LATE only through an eval fn
eval fn through() -> usize { return LATE }
eval LATE: usize = 5

pub struct Pt {
    pub var x: i32
    pub var y: i32
    eval fn Pt(self, x: i32, y: i32) {
        self.x = x
        self.y = y
    }
}
eval fn area(p: Pt) -> usize { return (p.x * p.y) as usize }  // needs Pt complete

class <eval N: usize> Buf {
    pub var data: [i32; N]
    fn Buf(self) { }
    fn cap(const self) -> usize { return N }
}
class <eval P: Pt> Grid {
    fn Grid(self) { }
    fn area(const self) -> i32 { return P.x * P.y }
}

class Holder {
    pub var a: [i32; twice(3)]               // a field
    pub var b: [i32; HALF]
    pub var c: [i32; quad(1)]
    pub var d: [i32; FROM_FN]
    pub var e: [i32; area(Pt(2, 2))]
    pub var buf: Buf<twice(1)>               // a value argument
    pub var g: Grid<Pt(2, 3)>
    pub var t: Table
    fn Holder(self) { }
}

fn first(const a: [i32; twice(3)]) -> i32 { return a[0] }   // a signature
var GLOBAL: [i32; twice(1)] = [7, 8]                       // a namespace-scope binding

fn main() -> i32 {
    var h = Holder()
    h.a[0] = 3
    h.e[3] = 4
    h.t.rows[3] = 2
    var k = (HALF + quad(1) + FROM_FN) as i32
    return first(h.a) + h.e[3] + GLOBAL[1] + (h.buf.cap() as i32) + h.g.area() + k + h.t.last()
        // 3 + 4 + 8 + 2 + 6 + (4 + 4 + 5) + 2 == 38
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// Each item is declared ahead of tier 1 and defined before the first
// record that needs it; Pt's constructor and `area` after Pt, LATE before
// FROM_FN, which reads it only through `through`.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}use.k
// IR:      consteval decltype(sizeof(0)) twice(decltype(sizeof(0)) x) noexcept;
// IR:      inline constexpr decltype(sizeof(0)) const LATE = 5;
// IR:      inline constexpr decltype(sizeof(0)) const FROM_FN = ::use::through();
// IR:      struct Pt {
// IR:      consteval Pt::Pt(signed int x, signed int y) noexcept {
// IR:      consteval decltype(sizeof(0)) area( ::use::Pt p) noexcept {
// IR:      consteval decltype(sizeof(0)) twice(decltype(sizeof(0)) x) noexcept {
// IR:      inline constexpr decltype(sizeof(0)) const HALF = ::lib::twice(2);
// IR:      class Table {
// IR-NEXT:     public: signed int rows[ ::lib::twice(2)];
// IR:      class Holder {
// IR-NEXT:     public: signed int a[ ::lib::twice(3)];
// IR-NEXT:     signed int b[ ::use::HALF];
// IR-NEXT:     signed int c[ ::use::quad(1)];
// IR-NEXT:     signed int d[ ::use::FROM_FN];
// IR-NEXT:     signed int e[ ::use::area( ::use::Pt(2, 2))];
// IR-NEXT:     ::use::Buf< ::lib::twice(1)> buf;
// IR-NEXT:     ::use::Grid< ::use::Pt(2, 3)> g;
// IR:      signed int first(const signed int(& a)[ ::lib::twice(3)]) noexcept;
// IR:      extern signed int GLOBAL[ ::lib::twice(1)];

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/c
// RUN: %t.exe; test $? -eq 38

// The header defines twice ahead of Table, which C++ consumers lay out.
// RUN: %kairo %S/lib.k --type-check-only --emit-headers %t.d/h
// RUN: %FileCheck %s --check-prefix=HDR < %t.d/h/lib.hh
// HDR:      consteval decltype(sizeof(0)) twice(decltype(sizeof(0)) x) noexcept;
// HDR:      consteval decltype(sizeof(0)) twice(decltype(sizeof(0)) x) noexcept {
// HDR:      class Table {
// HDR-NEXT:     public :
// HDR-NEXT:     signed int rows[::lib::twice(2)];
// HDR-NOT:  consteval decltype(sizeof(0)) twice(decltype(sizeof(0)) x) noexcept {
// REQUIRES: kcc
// RUN: cd %S && %kcc -c host.cc -o %t.d/host.o
// RUN: %kcc %t.d/host.o -o %t.d/app && %t.d/app; test $? -eq 42
