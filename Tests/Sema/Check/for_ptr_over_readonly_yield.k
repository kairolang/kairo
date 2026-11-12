// `for *x` over a user generator points at what each `yield` hands over.
// A field read through `const self` is yielded from a frame copy, and a
// computed value is a temporary: a write through `x` would change neither
// the container nor a later read, so `x` points to const there. A
// generator that yields a mutable place keeps a writable `x`.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s

class Bag {
    pub var a:   [i32]
    pub var buf: *i32

    fn Bag(self, p: *i32) {
        self.a   = [1, 2]
        self.buf = p
    }

    pub fn op in (const self) -> yield i32 {
        for var i: usize = 0; i < self.a.size(); ++i {
            yield self.a[i]
        }
    }

    pub fn squares(const self) -> yield i32 {
        yield 4
    }

    pub fn places(const self) -> yield i32 {
        yield self.buf[0]
    }
}

fn main() -> i32 {
    var cell = 0
    var b    = Bag(&cell)
    for *x in b {
        // CHECK: for_ptr_over_readonly_yield.k:[[@LINE+1]]:9: error [SC071E]: cannot assign to '*x': 'x' points to const
        *x = 10
    }

    for *y in b.squares() {
        // CHECK: for_ptr_over_readonly_yield.k:[[@LINE+1]]:9: error [SC071E]: cannot assign to '*y': 'y' points to const
        *y = 1
    }

    var t = 0
    for *r in b {
        t += *r
    }

    for *z in b.places() {
        *z = 7
    }

    return t + cell
}

// CHECK-NOT: error
