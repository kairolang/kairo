// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 56
// `yield` of a place that is const in the generated C++ but whose
// Kairo type says nothing -- a field of `self` in a `const self` generator,
// a field of a `const` parameter -- would bind neither of YieldPromise's
// `yield_value` overloads (CL001E "would lose const qualifier"). It is
// copied to a frame local first, as a const-typed value is.
// An element of a fixed array field and of a vector field are const the
// same way; a field reached through a pointer is not.

struct Pt {
    var x: i32 = 0
    var y: i32 = 0
}

class Bag {
    var n: i32 = 4
    var p: Pt
    var arr: [i32; 2] = [5, 6]
    var vec: [i32]
    var at: *Pt
    fn Bag(self, q: *Pt) {
        self.p = Pt { x: 1, y: 2 }
        self.vec.push(7)
        self.at = q
    }

    fn elems(const self) -> yield i32 {
        yield self.arr[1]
        yield self.vec[0]
        yield self.at->x
    }

    fn items(const self) -> yield i32 {
        yield self.n
        yield self.p.y
    }

    fn pts(const self) -> yield Pt {
        yield self.p
    }
}

fn from_param(const b: Bag) -> yield i32 {
    yield b.n
    const k: i32 = 7
    yield k
}

fn main() -> i32 {
    var q = Pt { x: 1, y: 0 }
    var b = Bag(&q)
    var s: i32 = 0
    for v in b.elems() {
        s += v // 6 + 7 + 1
    }

    for v in b.items() {
        s += v // 4 + 2
    }

    for q in b.pts() {
        s += q.x + q.y // 3
    }

    for v in from_param(b) {
        s += v // 4 + 7
    }

    return s + 22 // 56
}
