// After `x.finally()` a whole assignment of a new value constructs the
// local again (Compiler/Spec/Lowering.md#union-storage-locals): the storage
// holds no object, so no destructor of an old value and no assignment run; the
// local is usable again and its scope's end destroys it again, unless
// another `finally()` ends it first. Reached with the object maybe there
// (ended on one path only), the assignment destroys what `live` says is
// there, then constructs. Each object below is destroyed exactly once.
import std::io::println

class Res {
    var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    @move fn Res(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
    fn op finally(self) { println(f"~Res {self.id}") }
}

fn then_scope_end() {
    var r = Res(1)
    r.finally()
    r = Res(2)
    println(f"remade {r.id}")
}

fn then_finally_again() {
    var r = Res(3)
    r.finally()
    r = Res(4)
    r.finally()
    println("twice")
}

fn on_one_branch(c: bool) {
    var r = Res(5)
    r.finally()
    if c {
        r = Res(6)
    }
    println("one branch")
}

fn maybe_ended(c: bool) {
    var r = Res(7)
    if c {
        r.finally()
    }
    r = Res(8)
    println(f"maybe {r.id}")
}

fn in_loop() {
    var r = Res(10)
    for var i: i32 = 0; i < 2; ++i {
        r.finally()
        r = Res(11 + i)
    }
    println(f"loop {r.id}")
}

fn main() -> i32 {
    then_scope_end()
    then_finally_again()
    on_one_branch(true)
    on_one_branch(false)
    maybe_ended(true)
    maybe_ended(false)
    in_loop()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: void then_finally_again() noexcept {
// CXX: ::__kairo_ul< ::{{.*}}::Res> __k_s_r {
// CXX: __k_s_r.__end();
// CXX-NEXT: ( ::new(static_cast<void *>(& __k_s_r.v), ::__kairo_ulp {
// CXX: ) decltype(__k_s_r.v)( ::{{.*}}::Res(4)), void());
// CXX-NEXT: __k_s_r.__end();
// CXX-LABEL: void maybe_ended(bool c) noexcept {
// CXX: (__k_s_r.__kill(), ::new(static_cast<void *>(& __k_s_r.s.v), ::__kairo_ulp {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      ~Res 1
// OUT-NEXT: remade 2
// OUT-NEXT: ~Res 2
// OUT-NEXT: ~Res 3
// OUT-NEXT: ~Res 4
// OUT-NEXT: twice
// OUT-NEXT: ~Res 5
// OUT-NEXT: one branch
// OUT-NEXT: ~Res 6
// OUT-NEXT: ~Res 5
// OUT-NEXT: one branch
// OUT-NEXT: ~Res 7
// OUT-NEXT: maybe 8
// OUT-NEXT: ~Res 8
// OUT-NEXT: ~Res 7
// OUT-NEXT: maybe 8
// OUT-NEXT: ~Res 8
// OUT-NEXT: ~Res 10
// OUT-NEXT: ~Res 11
// OUT-NEXT: loop 12
// OUT-NEXT: ~Res 12
// OUT-EMPTY:
