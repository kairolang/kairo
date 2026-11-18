// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 21
// A variant's payload member is `__kairo_<V>` and its type
// `__kairo_<V>_t`, so a variant named `Tag` redeclared the tag enum
// `__kairo_Tag`, and variants `A` and `A_t` declared `__kairo_A_t` twice
// (CL001E "member of anonymous union redeclares"). Only such names are
// escaped; every other variant keeps its spelling. The other fixed member
// names (`tag`, `vt`, `destroy`, `get`, ...) were checked by a run and do
// not collide.

enum E {
    Tag { x: i32 },
    A { y: i32 },
    A_t { z: i32 },
    f_A { w: i32 },
    Plain,
}

enum <T> G {
    Tag { v: T },
    B { v: T },
    B_t { v: T },
}

fn e(x: E) -> i32 = match x {
    case .Tag(var x) => x
    case .A(var y) => y
    case .A_t(var z) => z
    case .f_A(var w) => w
    case .Plain => 0
}

fn g(x: G<i32>) -> i32 = match x {
    case .Tag(var v) => v
    case .B(var v) => v
    case .B_t(var v) => v
}

fn main() -> i32 {
    var n = e(E::Tag { x: 1 }) + e(E::A { y: 2 }) + e(E::A_t { z: 3 }) + e(E::f_A { w: 4 }) + e(E::Plain)
    return n + g(G<i32>::Tag { v: 5 }) + g(G<i32>::B { v: 0 }) + g(G<i32>::B_t { v: 6 }) // 10 + 11
}
