// A conformance or a member that comes from an `extend` with bounds exists
// for an instance only when the bounds hold for its arguments. `Box<B>` is
// not Small, although `extend <T impl Small> Box<T> impl Small` makes
// `Box<A>` one. Of two extensions declaring one member, the one whose bounds
// fail is not viable, and when both hold the one with the stricter bounds
// wins, with or without arguments.

interface Small {
    fn small(const self) -> i32
}

interface Big {
    fn big(const self) -> i32
}

class A {
    pub fn A(self) { }
}

class B {
    pub fn B(self) { }
}

extend A impl Small {
    fn small(const self) -> i32 = 1
}

class <T> Box {
    pub var v: T
}

class <T> Crate {
    pub var v: T
}

extend <T impl Small> Box<T> impl Small {
    fn small(const self) -> i32 = self.v.small()
}

extend <T> Crate<T> impl Small requires T impl Small {
    fn small(const self) -> i32 = self.v.small()
}

fn <T> pick(const x: T) -> i32 requires T impl Small {
    return 20
}

fn <T> pick(const x: T) -> i32 requires !(T impl Small) {
    return 10
}

extend <T> Box<T> {
    pub fn <C> choose(self) -> i32 = 10
}

extend <T impl Small> Box<T> {
    pub fn <C> choose(self) -> i32 = 20
}

extend <T> Box<T> {
    pub fn <C> nudge(self, x: i32) -> i32 = x + 10
}

extend <T impl Small> Box<T> {
    pub fn <C> nudge(self, x: i32) -> i32 = x + 20
}

extend <T impl Small> Crate<T> {
    pub fn only(self) -> i32 = 1
}

extend <T impl Big> Crate<T> {
    pub fn only(self) -> i32 = 2
}

fn main() -> i32 {
    var a = Box<A> { v: A() }
    var b = Box<B> { v: B() }
    var ca = Crate<A> { v: A() }
    var cb = Crate<B> { v: B() }
    var r = (pick(a) - 20) + (pick(b) - 10) + (pick(ca) - 20) + (pick(cb) - 10)
    r += (a.choose<i32>() - 20) + (b.choose<i32>() - 10)
    r += (a.nudge<i32>(1) - 21) + (b.nudge<i32>(1) - 11)
    return r + ca.only() - 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
