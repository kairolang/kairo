// `op in -> yield *T` hands out each element's address. Over it `for *p`
// binds the yielded pointer itself, so a write through `p` lands in the
// container; `for x` binds a copy of the element, so a write to `x`
// changes nothing. Through `op in (const self)`, `for const *p` reads the
// element in place. A tuple binder list destructures the element the
// pointer points at.

class Bag {
    var xs: [i32]

    fn Bag(self) {
        self.xs = [1, 2, 3]
    }

    fn op in (self) -> yield *i32 {
        for var i: usize = 0; i < self.xs.size(); ++i {
            yield &self.xs[i]
        }
    }

    fn op in (const self) -> yield *const i32 {
        for var i: usize = 0; i < self.xs.size(); ++i {
            yield &self.xs[i]
        }
    }
}

class Pairs {
    var ps: [(i32, i32)]

    fn Pairs(self) {
        self.ps = [(1, 0), (2, 0)]
    }

    fn op in (self) -> yield *(i32, i32) {
        for var i: usize = 0; i < self.ps.size(); ++i {
            yield &self.ps[i]
        }
    }
}

class Raw {
    var xs: [i32]

    fn Raw(self) {
        self.xs = [5, 6]
    }

    fn op in (self) -> yield unsafe *i32 {
        for var i: usize = 0; i < self.xs.size(); ++i {
            unsafe {
                yield &self.xs[i] as unsafe *i32
            }
        }
    }
}

fn sum(const b: Bag) -> i32 {
    var s = 0
    for const *p in b { // the const form, read in place
        s += *p
    }

    for const x in b {
        s += 0 * x
    }

    return s
}

fn main() -> i32 {
    var b = Bag()
    // DIAG: op_in_pointer_yield.k:[[@LINE+2]]:9: warning [SC275W]: this writes to a copy of the element; the collection is not changed
    for x in b { // a copy: the element keeps its value
        x = 100
    }

    for *p in b { // writes 10, 20, 30 into b.xs
        *p = *p * 10
    }

    var s = 0
    for x in b { // 60
        s += x
    }

    s += sum(b) // 60

    var ps = Pairs()
    for (a, *c) in ps { // second field := first * 2
        *c = a * 2
    }

    for (a, c) in ps { // 2 + 4
        s += c
    }

    var r = Raw()
    for unsafe *q in r {
        unsafe {
            *q = *q + 1
        }
    }

    for unsafe *q in r { // 6 + 7
        unsafe {
            s += *q
        }
    }

    return s // 60 + 60 + 6 + 13 = 139
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 139
