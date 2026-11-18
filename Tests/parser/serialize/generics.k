// Generic declarations in a serialized AST: generic parameter lists with
// bounds, defaults, value parameters and packs, `requires` clauses,
// specializations (spec_args, spec_kind is the parser's), generic argument
// lists on names and chains, and a generic parameter's back-pointer to the
// declaration that owns it, which is a reference to a node still being
// read when the reader meets it.

interface Shape {
    fn area(self) -> i32
}

class Square impl Shape {
    pub var side: i32
    pub fn Square(self, side: i32) { self.side = side }
    pub fn area(self) -> i32 { return self.side * self.side }
}

struct <T> Box {
    pub var value: T
}

struct <T, U = i32> Two {
    pub var first: T
    pub var second: U
}

struct <eval N: usize> Buf {
    pub var data: [u8; N]
}

struct <> Box<bool> {
    pub var flag: bool
}

enum <T> Maybe {
    Some { value: T },
    None,
}

fn <T impl Shape> measure(s: T) -> i32 {
    return s.area()
}

fn <T> pick(a: T, b: T, first: bool) -> T requires sizeof(T) > 0 {
    if first {
        return a
    }

    return b
}

fn <...T> ignore(...args: T) {
}

type <T> Boxes = [Box<T>]

extend <T> Box<T> {
    pub fn get(self) -> T { return self.value }
}

fn main() -> i32 {
    var b = Box<i32> { value: 4 }
    var t = Two<i32, i64> { first: 1, second: 2 }
    var sq = Square(3)
    return measure<Square>(sq) + pick<i32>(b.get(), 0, false) + (t.first - 1) - 9
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only --verify-ast-roundtrip 2>&1 || true; } | %FileCheck %s --check-prefix=VERIFY --allow-empty
// VERIFY-NOT: I002F
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } > %t.parsed
// RUN: { %kairo %s --syntax-only --print-ast=tree --ast-roundtrip 2>/dev/null || true; } > %t.reloaded
// RUN: diff %t.parsed %t.reloaded
// RUN: %FileCheck %s < %t.reloaded
// CHECK: GenericParamDecl
// RUN: { %kairo %s --type-check-only 2>&1 || true; } > %t.diag.parsed
// RUN: { %kairo %s --type-check-only --ast-roundtrip 2>&1 || true; } > %t.diag.reloaded
// RUN: diff %t.diag.parsed %t.diag.reloaded
