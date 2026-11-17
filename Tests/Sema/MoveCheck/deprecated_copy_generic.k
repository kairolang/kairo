// An implicit copy of an instance of a generic class whose `@copy`
// constructor is `@deprecated` (SC354W) carries the `.copy()` fix-it when
// the class declares `pub fn copy(const self)` returning the class, spelled
// either as `Self` or by its own name with its parameters (`Bag<T>`): the
// method is declared on the pattern and found from the instance.

// RUN: { %kairo --type-check-only %s || true; } 2>&1 | %FileCheck %s

class <T> Bag {
    pub var n: i32

    pub fn Bag(self, n: i32) {
        self.n = n
    }

    @deprecated("copy with .copy()")
    @copy pub fn Bag(self, const other: Self) {
        self.n = other.n
    }

    pub fn copy(const self) -> Bag<T> {
        return Bag<T>(self.n)
    }
}

class <T> Sack {
    pub var n: i32

    pub fn Sack(self, n: i32) {
        self.n = n
    }

    @deprecated("copy with .copy()")
    @copy pub fn Sack(self, const other: Self) {
        self.n = other.n
    }

    pub fn copy(const self) -> Self {
        return Sack<T>(self.n)
    }
}

fn sites(a: Bag<i32>, s: Sack<u8>) -> i32 {
    var b = a
    // CHECK: [[@LINE-1]]:13: warning [SC354W]: implicit copy of a 'Bag<i32>'
    // CHECK: note [I900N]: the transfer into 'b' copies 'a'
    // CHECK: fix-it:{{.*}}:{[[@LINE-3]]:14-[[@LINE-3]]:14}:".copy()"
    var t = s
    // CHECK: [[@LINE-1]]:13: warning [SC354W]: implicit copy of a 'Sack<u8>'
    // CHECK: fix-it:{{.*}}:{[[@LINE-2]]:14-[[@LINE-2]]:14}:".copy()"
    return b.n + t.n
}
