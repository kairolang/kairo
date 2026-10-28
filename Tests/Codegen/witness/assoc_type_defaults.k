// An associated type's default applies to an EXPLICIT conformer that does
// not declare the type (interfaces.md, Defaults): V takes `Index = i64`,
// W declares its own `i32`. A default may name an earlier associated type
// (`Pair = (Self::Index, Self::Index)`), read with Self := the conformer.
// The specialization spells whichever was chosen.

interface Indexed {
    type Index = i64
    type Pair = (Self::Index, Self::Index)
    fn at(const self, i: Self::Index) -> i32
    fn both(const self) -> Self::Pair
    fn zero(const self) -> Self::Index
}

class V impl Indexed {
    fn V(self) { }
    fn at(const self, i: i64) -> i32 { return (i * 2) as i32 }
    fn both(const self) -> (i64, i64) { return (3, 4) }
    fn zero(const self) -> i64 { return 4 }
}

class W impl Indexed {
    type Index = i32
    fn W(self) { }
    fn at(const self, i: i32) -> i32 { return i + 100 }
    fn both(const self) -> (i32, i32) { return (5, 6) }
    fn zero(const self) -> i32 { return 6 }
}

fn <T impl Indexed> go(t: T) -> i32 {
    var p: T::Pair = t.both()
    return t.at(t.zero())
}

fn <T impl Indexed> pair(t: T) -> T::Pair { return t.both() }

fn main() -> i32 {
    var p: (i64, i64) = pair(V())
    var q: (i32, i32) = pair(W())
    return go(V()) + go(W()) + (p.1 as i32) + q.0   // 8 + 106 + 4 + 5
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: internal compiler error
// CXX: template<> struct Indexed_witness< ::assoc_type_defaults::V> {
// CXX-NEXT: using Index = signed long;
// CXX: template<> struct Indexed_witness< ::assoc_type_defaults::W> {
// CXX-NEXT: using Index = signed int;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 123
