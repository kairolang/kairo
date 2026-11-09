// A MOVE class's derived `op =` is self-check, destroy, then the `@move`
// constructor's body on the right-hand side, which is moved: reading it
// afterwards is SC052E (classes-lifecycle.mdx). C++ gets one
// `operator=(M&&)`; the user-declared move constructor deletes the copy
// constructor and copy assignment.

import std::io

class M {
    pub var v: i32 = 0
    fn M(self, v: i32) { self.v = v }
    @move fn M(self, other: Self) {
        self.v = other.v + 100
        other.v = -1
        io::println("move")
    }
    fn op finally(self) { io::println(f"del {self.v}") }
}

fn main() -> i32 {
    var a = M(1)
    var b = M(2)
    io::println("assign")
    a = b
    io::println(f"a={a.v}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir -o /dev/null 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR: M( ::derived_assign_move::M && other) noexcept;
// IR: M & operator =( ::derived_assign_move::M && o) noexcept {
// IR-NEXT: if(this != & o) {
// IR-NEXT: this->M::~M();
// IR-NEXT: ::new(static_cast<void *>(this)) M(static_cast<M &&>(o));
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: assign
// OUT-NEXT: del 1
// OUT-NEXT: move
// OUT-NEXT: a=102
// OUT-NEXT: del -1
// OUT-NEXT: del 102
