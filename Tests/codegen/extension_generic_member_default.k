// A default argument on a member of a generic extension: the default's
// thunk is a member of the same extension scope, and the call names its
// instance with the extension's arguments, then the member's own.
// RUN: %kairo %s -o %t.exe
// RUN: { %t.exe || true; } | %FileCheck %s
import std::io

class <T> Box {
    pub var v: T

    fn Box(self, const v: T) {
        self.v = v
    }
}

extend <T> Box<T> {
    pub fn join(self, const sep: string = "-") -> string {
        return f"a{sep}b"
    }

    pub fn <U> pick(self, const u: U, const k: i32 = 5) -> i32 {
        return k
    }
}

fn main() -> i32 {
    var b = Box<i32>(3)
    // CHECK: a-b
    io::println(b.join())
    // CHECK-NEXT: a+b
    io::println(b.join("+"))
    // CHECK-NEXT: 5 9
    io::println(f"{b.pick(1.5)} {b.pick(true, 9)}")
    return 0
}
