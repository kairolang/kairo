// A nullable of an associated type keeps its element type: `x ?? 0` over an
// `I::Item?` whose Item is a record (not an integer) does not convert, and the
// instance is rejected instead of compiling to something else.

interface Getter {
    fn get(const self) -> i32
}

class Num {
    pub var v: i32 = 0
    pub fn get(const self) -> i32 { return self.v }
}

extend Num impl Getter {}

interface Boxed {
    type Item impl Getter
    fn next(self) -> Self::Item?
}

class Five { var n: i32 = 0 }

extend Five impl Boxed {
    type Item = Num
    fn next(self) -> Num? { return null }
}

fn <I impl Boxed> bad(it: I) -> i32 {
    var x = it.next()
    return x ?? 0
}

fn main() -> i32 { return bad(Five()) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -o %t.exe 2>&1 || true; } | %FileCheck %s --implicit-check-not='I003E' --implicit-check-not='I011W'
// CHECK: assoc_item_nullable_reject.k:{{[0-9]+}}:{{[0-9]+}}: error [CL001E]: incompatible operand types
