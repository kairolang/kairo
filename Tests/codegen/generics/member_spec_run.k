// A method of a generic class is specialized from an extension of it:
//   A  `extend <T> G<T> { fn <> m<i32>(...) }`: m<i32>, on every instance;
//   B  `extend G<u8> { fn <U> m(...) }`: every m, on G<u8> only;
//   C  `extend G<u8> { fn <> m<i32>(...) }`: both fixed, which also
//      decides G<u8>.m<i32> where an A and a B both apply.
// A call names the class's method; its body picks the specialization per
// instance, so a generic caller and a C++ caller get the same body.

class <T> G {
    pub var v: i32 = 7
    fn <U> m(self) -> i32 { return 1 }
    fn <U> add(self, x: U) -> i32 { return 0 }
    fn k(const self) -> i32 { return 5 }
    static fn <U> s() -> i32 { return 10 }
}

extend <T> G<T> {
    fn <> m<i32>(self) -> i32 { return 2 }
    fn <> add<i32>(self, x: i32) -> i32 { return x + self.v }
    static fn <> s<bool>() -> i32 { return 11 }
}

extend G<u8> {
    fn <U> m(self) -> i32 { return 3 }
    fn k(const self) -> i32 { return self.v - 1 }
}

extend G<u8> {
    fn <> m<i32>(self) -> i32 { return 4 }
}

fn <X, Y> call(g: *G<X>) -> i32 { return g->m<Y>() }

fn main() -> i32 {
    var a = G<i16>()
    var b = G<u8>()
    if a.m<i32>() != 2 || a.m<u16>() != 1 { return 1 }
    if b.m<u16>() != 3 || b.m<i32>() != 4 { return 2 }
    if call<i16, i32>(&a) != 2 || call<u8, u16>(&b) != 3 || call<u8, i32>(&b) != 4 { return 3 }
    if a.add<i32>(5) != 12 || a.add<u8>(5) != 0 { return 4 }
    if a.k() != 5 || b.k() != 6 { return 5 }
    if G<i16>::s<bool>() != 11 || G<i16>::s<i32>() != 10 { return 6 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
