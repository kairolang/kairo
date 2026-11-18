// A use after a move names the fix when the moved type makes its own
// copies: a public `fn copy(const self) -> Self` (what std's CopiesItself
// requires) draws a note at the move with a fix-it that appends `.copy()`.
// A type with no such method, or with a private one, draws no such note.

// RUN: { %kairo --type-check-only %s || true; } 2>&1 | %FileCheck %s

class Buf {
    pub var n: i32 = 0

    pub fn Buf(self) { }

    @move pub fn Buf(self, other: Self) {
        self.n = other.n
    }

    pub fn copy(const self) -> Self {
        var b = Buf()
        b.n = self.n
        return b
    }
}

class Plain {
    pub var n: i32 = 0

    pub fn Plain(self) { }

    @move pub fn Plain(self, other: Self) {
        self.n = other.n
    }
}

class Hidden {
    pub var n: i32 = 0

    pub fn Hidden(self) { }

    @move pub fn Hidden(self, other: Self) {
        self.n = other.n
    }

    priv fn copy(const self) -> Self {
        return Hidden()
    }
}

fn eat(b: Buf) -> i32 {
    return b.n
}

fn with_copy() -> i32 {
    var a = Buf()
    var b = a
    return a.n + b.n
}

// CHECK: [[@LINE-3]]:12: error [SC052E]: 'a' is used after being moved
// CHECK: [[@LINE-5]]:14: note [I900N]: 'a' has a 'copy' method: write 'a.copy()' here if a copy was meant
// CHECK: fix-it:{{.*}}:{[[@LINE-6]]:14-[[@LINE-6]]:14}:".copy()"

fn through_call() -> i32 {
    var a = Buf()
    var n = eat(a)
    return a.n + n
}

// CHECK: [[@LINE-3]]:12: error [SC052E]: 'a' is used after being moved
// CHECK: [[@LINE-5]]:18: note [I900N]: 'a' has a 'copy' method: write 'a.copy()' here if a copy was meant

fn no_copy() -> i32 {
    var a = Plain()
    var b = a
    return a.n + b.n
}

// CHECK: [[@LINE-3]]:12: error [SC052E]: 'a' is used after being moved
// CHECK-NOT: has a 'copy' method

fn hidden_copy() -> i32 {
    var a = Hidden()
    var b = a
    return a.n + b.n
}

// CHECK: [[@LINE-3]]:12: error [SC052E]: 'a' is used after being moved
// CHECK-NOT: has a 'copy' method
