// A local `finally()` ends is stored as the member of a union, and every
// use names that member, never a reference to it
// (Compiler/Spec/Lowering.md#union-storage-locals): `&x` is the object's
// address and a pointer to it reads its fields. The C++ layout itself
// (size, alignment, offset, declared type) is CLI/Kcc/kcc_finally_layout.k.
// `a` is unflagged (ended on every path), `b` flagged (on one).
import std::io::println

class Wide {
    var x: i64 = 1
    var y: i8  = 2
    fn Wide(self) = default
    fn op finally(self) { println("~Wide") }
}

fn addr(p: *Wide) -> usize {
    return unsafe ((p as unsafe *u8) as usize)
}

fn probe(c: bool) -> i32 {
    var a   = Wide()
    var b   = Wide()
    var bad = 0
    if addr(&a) % 8 != 0 || addr(&b) % 8 != 0 {
        bad += 1
    }

    var pa = &a
    var pb = &b
    if pa->x != 1 || pa->y != 2 || pb->x != 1 || pb->y != 2 {
        bad += 2
    }

    if addr(pa) != addr(&a) {
        bad += 4
    }

    a.finally()
    if c {
        b.finally()
    }

    return bad
}

fn main() -> i32 {
    var r = probe(true) + probe(false)
    println(f"bad {r}")
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: signed int probe(bool c) noexcept {
// CXX: ::__kairo_ul< {{.*}}Wide> __k_s_a {
// CXX: ::__kairo_ulf< {{.*}}Wide> __k_s_b {
// CXX-NOT: Wide &
// CXX: addr((& __k_s_a.v))
// CXX: addr((& __k_s_b.s.v))
// CXX: Wide * pa =(& __k_s_a.v);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      ~Wide
// OUT-NEXT: ~Wide
// OUT-NEXT: ~Wide
// OUT-NEXT: ~Wide
// OUT-NEXT: bad 0
// OUT-EMPTY:
