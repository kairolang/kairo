// `x.finally()` on a local whose type is a generic parameter is decided
// per instance (Compiler/Spec/Lowering.md#union-storage-locals): the body
// is one C++ template, and its union storage is valid for every T. An
// instance whose T has a destructor runs it at the call, and not again at
// the scope's end; a trivially destroyed T runs nothing. Instantiated with
// a class that has a destructor, a plain struct, and a move-only class.
import std::io::println

interface Tagged { fn tag(const self) -> i32 }

class Res {
    var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    @copy fn Res(self, const other: Self) = default
    fn op finally(self) { println(f"~Res {self.id}") }
}

struct Plain { var v: i32 }

class Mv {
    var id: i32 = 0
    fn Mv(self, id: i32) { self.id = id }
    @move fn Mv(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
    fn op finally(self) { println(f"~Mv {self.id}") }
}

extend Res impl Tagged { fn tag(const self) -> i32 { return self.id } }
extend Plain impl Tagged { fn tag(const self) -> i32 { return self.v } }
extend Mv impl Tagged { fn tag(const self) -> i32 { return self.id } }

fn <T impl Tagged> end_early(x: T) -> i32 {
    var y = x
    var t = y.tag()
    y.finally()
    println(f"ended {t}")
    return t
}

fn main() -> i32 {
    var a = end_early(Res(1))
    var b = end_early(Plain { v: 2 })
    var c = end_early(Mv(3))
    println(f"sum {a + b + c}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      ~Res 1
// OUT-NEXT: ended 1
// OUT-NEXT: ~Res 1
// OUT-NEXT: ended 2
// OUT-NEXT: ~Mv 3
// OUT-NEXT: ended 3
// OUT-NEXT: ~Mv 0
// OUT-NEXT: sum 6
// OUT-EMPTY:
