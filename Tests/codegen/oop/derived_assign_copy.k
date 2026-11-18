// `op =` is derived from the transfer constructor (classes-lifecycle.mdx,
// "Assignment is auto-derived"): for a COPY class with a `@copy` body it
// checks for self-assignment, destroys the old value, and copy-constructs
// the right-hand side in place. `a = a` does nothing at all. C++ gets one
// `operator=(const C&)`; declaring the copy constructor leaves no move.

import std::io

class C {
    pub var v: i32 = 0
    fn C(self, v: i32) { self.v = v }
    @copy fn C(self, const other: Self) {
        self.v = other.v + 100
        io::println(f"copy {other.v}")
    }
    fn op finally(self) { io::println(f"del {self.v}") }
}

fn main() -> i32 {
    var a = C(1)
    var b = C(2)
    io::println("assign")
    a = b
    io::println(f"a={a.v}")
    a = a
    io::println(f"self a={a.v}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir -o /dev/null 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR: C & operator =(const::derived_assign_copy::C & o) noexcept {
// IR-NEXT: if(this != & o) {
// IR-NEXT: this->C::~C();
// IR-NEXT: ::new(static_cast<void *>(this)) C(o);
// IR-NOT: C & operator =( ::derived_assign_copy::C && o)
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: assign
// OUT-NEXT: del 1
// OUT-NEXT: copy 2
// OUT-NEXT: a=102
// OUT-NEXT: self a=102
// OUT-NEXT: del 2
// OUT-NEXT: del 102
