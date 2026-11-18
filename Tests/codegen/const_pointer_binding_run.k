// `const p: *T` freezes the pointer and leaves the pointee writable: the
// C++ is `T *const p` for a parameter, a local, a field, a global and a
// closure parameter, so a mutating method and an assignment through the
// pointer compile. `const p: *const T` freezes both. A function with a
// `const p: *T` parameter is a `fn(*T)` value.

class W {
    pub var n: i32 = 0
    fn bump(self) {
        self.n += 1
    }
}

class Holder {
    pub const p: *W
    fn Holder(self, p: *W) {
        self.p = p
    }
}

var gw: W
const gp: *W = &gw

fn one(const p: *W) -> i32 {
    p->bump()
    *p = W()
    p->n += 2
    return p->n
}

fn two(const pp: **W) -> i32 {
    (*pp)->bump()
    return (*pp)->n
}

fn both(const p: *const W) -> i32 {
    return p->n
}

fn arr(const pa: *[i32; 3]) -> i32 {
    (*pa)[0] = 5
    return (*pa)[0]
}

fn main() -> i32 {
    var w = W()
    if one(&w) != 2 { return 1 }

    var h = Holder(&w)
    h.p->bump()
    if w.n != 3 { return 2 }

    gp->bump()
    if gw.n != 1 { return 3 }

    var pw: *W = &w
    if two(&pw) != 4 || both(const &w) != 4 { return 4 }

    var a: [i32; 3] = [1, 2, 3]
    const ap: *[i32; 3] = &a
    (*ap)[1] = 7
    if arr(&a) != 5 || a[1] != 7 { return 5 }

    const q: *W = &w
    q->bump()
    var f: fn(*W) -> i32 = one
    var g = fn (const z: *W) -> i32 {
        z->bump()
        return z->n
    }
    if f(q) != 2 || g(q) != 3 { return 6 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: W * const p;
// CXX: W * const gp
// CXX: signed int one({{.*}}W * const p)
// CXX: signed int two({{.*}}W * * const pp)
// CXX: signed int both(const{{.*}}W * const p)
// CXX: signed int arr(signed int(* const pa)[3])
// CXX: signed int(* const ap)[3]
// CXX: W * const q
// CXX: W * const z
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
