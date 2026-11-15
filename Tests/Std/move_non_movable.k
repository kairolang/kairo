// std::move of a value whose type cannot be moved at all is SC051E at the
// argument, with the reason: a NON_TRANSFER class (both transfer
// constructors deleted, or only the move, or a copy deleted with no move),
// a class with such a field, and a temporary of one. The same error comes
// through any generic `@move` parameter, a wrapper of std::move included,
// at the instance's use.

import std

class Lock {
    pub var v: i32
    fn Lock(self, v: i32) {
        self.v = v
    }

    @copy fn Lock(self, const other: Self) = delete
    @move fn Lock(self, other: Self) = delete
}

class NoMove {
    pub var v: i32
    fn NoMove(self, v: i32) {
        self.v = v
    }

    @move fn NoMove(self, other: Self) = delete
}

class NoCopy {
    pub var v: i32
    fn NoCopy(self, v: i32) {
        self.v = v
    }

    @copy fn NoCopy(self, const other: Self) = delete
}

class Holder {
    pub var l: Lock = Lock(1)
}

fn <T> pass_on(@move x: T) -> T {
    return std::move(x)
}

fn main() -> i32 {
    var a = Lock(1)
    var b = NoMove(2)
    var c = NoCopy(3)
    var h = Holder()
    var w = Lock(5)
    std::move(a)
    std::move(b)
    std::move(c)
    std::move(h)
    std::move(Lock(4))
    pass_on(w)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: move_non_movable.k:52:15: error [SC051E]: cannot move a value of type 'Lock': its move constructor is deleted
// CHECK: move_non_movable.k:53:15: error [SC051E]: cannot move a value of type 'NoMove': its move constructor is deleted
// CHECK: move_non_movable.k:54:15: error [SC051E]: cannot move a value of type 'NoCopy': it declares no move constructor and its copy constructor is deleted
// CHECK: move_non_movable.k:55:15: error [SC051E]: cannot move a value of type 'Holder': its field 'l' is not movable
// CHECK: move_non_movable.k:56:15: error [SC051E]: cannot move a value of type 'Lock': its move constructor is deleted
// CHECK: move_non_movable.k:57:13: error [SC051E]: cannot move a value of type 'Lock': its move constructor is deleted
// CHECK-NOT: error
