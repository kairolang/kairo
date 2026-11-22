// A destructive class (MOVE, with a destructor) and functions that take it
// by value: C++ sees each parameter as `C&&`.
pub var dtors: i32 = 0

pub class C {
    pub var id: i32 = 0
    pub fn C(self, id: i32) { self.id = id }
    @move pub fn C(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op finally(self) { dtors += 1 }
}

fn sink(c: C) { }

// Reads its parameter: the caller's object is the caller's to destroy.
pub fn keep(c: C) -> i32 { return c.id }

// Moves its parameter out on every path.
pub fn take(c: C) -> C { return c }

// Moves it out on one path and destroys the value on the other.
pub fn maybe(c: C, b: bool) -> i32 {
    if b {
        sink(c)
        return 1
    }

    return 0
}

pub fn <T> pass(x: T) -> T { return x }

pub class Holder {
    pub var c: C
    pub fn Holder(self, c: C) { self.c = c }
}

pub fn count() -> i32 {
    var n = dtors
    dtors = 0
    return n
}

pub fn apply(f: fn(C) -> i32, c: C) -> i32 { return f(c) }
