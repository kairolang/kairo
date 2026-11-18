// A method whose `requires` clause is false for an instance is not a
// member of that instance (C++ drops it), so it does not implement an
// interface requirement there: `Box<Mv>` has no `dup`, `Box<i32>` has one.

// RUN: { %kairo --type-check-only %s || true; } 2>&1 | %FileCheck %s
// RUN: { %kairo --type-check-only %s || true; } 2>&1 | %FileCheck %s --check-prefix=COUNT

interface Dup {
    fn dup(const self) -> Self
}

class Mv {
    pub var n: i32

    pub fn Mv(self, n: i32) {
        self.n = n
    }

    @move pub fn Mv(self, other: Self) {
        self.n = other.n
    }
}

class <T> Box {
    pub var n: i32

    pub fn Box(self, n: i32) {
        self.n = n
    }

    pub fn dup(const self) -> Box<T> requires __builtin_is_constructible<T, const T>() {
        return Box<T>(self.n)
    }
}

fn <X impl Dup> twice(const x: X) -> X {
    return x.dup()
}

fn moves(const b: Box<Mv>) -> i32 {
    var c = twice(b)
    // CHECK: [[@LINE-1]]:13: error [SC162E]: 'Box<Mv>' does not conform to 'Dup': no member 'dup' with the requirement's signature
    return c.n
}

fn copies(const b: Box<i32>) -> i32 {
    var c = twice(b)
    return c.n
}

// COUNT-COUNT-1: error [SC162E]
// COUNT-NOT: error [SC162E]
