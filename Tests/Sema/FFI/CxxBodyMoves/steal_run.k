// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 79
//
// The reproducer's shape, compiled and run: after a C++ call that moves out
// of `h`, `h` is assigned again before it is read, and after one that only
// reads it, `h` is still the live value. 79 = 7 * 10 + 9.

ffi "c++" import "Inputs/moves.h"

class Res {
    pub var id: i32 = 0
    fn Res(self, id: i32) {
        self.id = id
    }

    @move fn Res(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
}

fn reassigned() -> i32 {
    var h = Res(7)
    steal(&h)
    h = Res(9)
    return h.id
}

fn kept() -> i32 {
    var h = Res(7)
    look(&h)
    return h.id
}

fn main() -> i32 {
    return kept() * 10 + reassigned()
}
