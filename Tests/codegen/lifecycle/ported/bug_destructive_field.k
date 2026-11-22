// Under the destructive-move rule a moved-from object is not destroyed, so
// a destructor that counts itself unconditionally runs once per object that
// is ever alive: a value moved into a field: one object, destroyed with its holder. The compiler emits C++ moves, so the destructor also
// runs on every moved-from object and the count is higher (ownership.mdx,
// Moved-From State: the source of a move is invalidated).

import std::io::println

var dtors: i32 = 0

class C {
    var id: i32 = 0
    fn C(self, id: i32) { self.id = id }
    @move fn C(self, other: Self) { self.id = other.id }
    fn op finally(self) { dtors += 1 }
}

class Holder {
    var c: C
    fn Holder(self, c: C) { self.c = c }
}

class Pair {
    var a: C
    var b: C
    fn Pair(self) { self.a = C(1); self.b = C(2) }
}

fn eat(c: C) { }

fn run(const name: string, want: i32) -> i32 {
    if dtors != want {
        println(f"FAIL {name}: {dtors} destructor calls, want {want}")
        return 1
    }
    return 0
}

fn shape() {
    var a = C(1)
    var h = Holder(a)
}
fn main() -> i32 {
    shape()
    return run("field", 1)
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2.d
// RUN: %t.o2.exe
