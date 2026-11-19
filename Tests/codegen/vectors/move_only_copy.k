// `[MoveOnly]` moves: a vector is move-only, whatever its element, so
// returning a named one and `var b = a` move it, and an element is built
// and moved in by `push`. Nothing is copied, so nothing reaches clang that
// would need a copy constructor.

class Mv {
    var v: i32
    fn Mv(self, v: i32) { self.v = v }
    @move fn Mv(self, other: Self) = default
}

fn make() -> [Mv] {
    var a: [Mv]
    a.push(Mv(1))
    return a
}

fn main() -> i32 {
    var a: [Mv]
    a.push(Mv(1))
    var b = a
    var c = make()
    return (b.size() + c.size()) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 2
