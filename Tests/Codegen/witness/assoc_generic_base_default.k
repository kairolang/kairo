// witness/assoc_generic_base_default.k -- exit 63
// A derived interface may give an associated type it inherits from a
// GENERIC interface a default (interfaces.md, "Associated types and
// inheritance"): `interface IntSource derives Source<i32> { type Item = Cell
// }` is Source<i32>'s Item, and an explicit conformer of IntSource takes the
// default. It was SC116E ("giving associated type 'Item' of a generic
// interface a default is not supported yet"); the same Item named through
// either interface is one type.
//
// Bodies bounded by the derived interface and by the generic base at the
// derived one's arguments, a conformer that takes the default and one that
// declares its own.

interface Show {
    fn show(const self) -> i32
}

interface <V> Source {
    type Item impl Show
    fn next(const self) -> Self::Item
    fn base(const self) -> V
}

struct Cell {
    pub var c: i32
}
extend Cell impl Show {
    fn show(const self) -> i32 = self.c
}

struct Big {
    pub var b: i32
}
extend Big impl Show {
    fn show(const self) -> i32 = self.b * 10
}

interface IntSource derives Source<i32> {
    type Item = Cell
}

class Taker impl IntSource {
    fn Taker(self) { }
    fn next(const self) -> Cell { return Cell { c: 3 } }
    fn base(const self) -> i32 { return 1 }
}

class Own impl IntSource {
    type Item = Big
    fn Own(self) { }
    fn next(const self) -> Big { return Big { b: 4 } }
    fn base(const self) -> i32 { return 2 }
}

fn <S impl IntSource> viaDerived(s: S) -> i32 {
    var x: S::Item = s.next()
    return x.show() + s.base()
}

fn <S impl Source<i32>> viaBase(s: S) -> i32 {
    var x: S::Item = s.next()
    return x.show()
}

fn main() -> i32 {
    // Taker: (3 + 1) + 3; Own: (40 + 2) + 40; 7 + 82 - 26
    return viaDerived(Taker()) + viaBase(Taker()) + viaDerived(Own()) + viaBase(Own()) - 26
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 63
