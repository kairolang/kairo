// `finally()` in a generator, beside a closure, and on a `const` local
// (Compiler/Spec/Lowering.md#union-storage-locals).
//  - A generator's locals live in its coroutine frame. One ended before a
//    `yield` is not destroyed again when the frame is destroyed; one the
//    consumer abandons before its `finally()` runs is destroyed with the
//    frame, by the same cleanup hook.
//  - A closure that copies the local before `finally()` holds its own
//    object, destroyed with the closure.
import std::io::println

class Res {
    var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    @copy fn Res(self, const other: Self) { self.id = other.id + 10 }
    fn op finally(self) { println(f"~Res {self.id}") }
    fn get(const self) -> i32 { return self.id }
}

fn gen() -> yield i32 {
    var r = Res(1)
    yield 1
    r.finally()
    yield 2
    println("gen done")
}

fn take(n: i32) {
    var k = 0
    for v in gen() {
        println(f"got {v}")
        k += 1
        if k == n {
            break
        }
    }
    println(f"took {n}")
}

fn captured() {
    var r = Res(2)
    var f = fn () -> i32 { return r.get() }
    r.finally()
    println(f"closure reads {f()}")
}

fn konst() {
    const r = Res(3)
    println(f"const {r.get()}")
    r.finally()
    println("after const")
}

fn main() -> i32 {
    take(1)
    take(2)
    take(3)
    captured()
    konst()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The generator's local is flagged (a `yield` is an exit), the closure
// copies the object out of its storage.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: ::__kairo_ulf< ::{{.*}}::Res> __k_s_r {
// CXX: [r = __k_s_r.v]
// CXX: ::__kairo_ul<const{{ *}}::{{.*}}::Res> __k_s_r {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      got 1
// OUT-NEXT: ~Res 1
// OUT-NEXT: took 1
// OUT-NEXT: got 1
// OUT-NEXT: ~Res 1
// OUT-NEXT: got 2
// OUT-NEXT: took 2
// OUT-NEXT: got 1
// OUT-NEXT: ~Res 1
// OUT-NEXT: got 2
// OUT-NEXT: gen done
// OUT-NEXT: took 3
// OUT-NEXT: ~Res 2
// OUT-NEXT: closure reads 12
// OUT-NEXT: ~Res 12
// OUT-NEXT: const 3
// OUT-NEXT: ~Res 3
// OUT-NEXT: after const
// OUT-EMPTY:
