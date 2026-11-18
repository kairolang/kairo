// `unsafe *C as unsafe *B` where C derives B lands on the B subobject, the
// address an implicit upcast already gives. B is C's SECOND base, so it sits
// at a nonzero offset: lowered as a reinterpret the cast kept C's address
// and read A's field through it. The downcast back is the mirror. Unrelated
// pointees still reinterpret.

class A {
    var a: i32 = 0
}

class B {
    var b: i32 = 0
}

class C derives A, B {
    var c: i32 = 0
}

class D {
    var d: i32 = 0
}

fn implicit_up(p: unsafe *C) -> unsafe *B {
    return p
}

fn main() -> i32 {
    var c = C()
    c.a = 1
    c.b = 2
    c.c = 3
    var pb: unsafe *B = &null
    var pc: unsafe *C = &null
    var pd: unsafe *D = &null
    unsafe {
        pc = &c as unsafe *C
        pb = pc as unsafe *B
        if pb->b != 2 { return 1 }
        if pb != implicit_up(pc) { return 2 }
        var unsafe *back = pb as unsafe *C
        if back != pc { return 3 }
        if back->c != 3 { return 4 }
        // unrelated: the same bits, so D's first field is A's.
        pd = pc as unsafe *D
        if pd->d != 1 { return 5 }
    }
    return 42
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}raw_pointer_base_cast.k
// CXX: pb = static_cast<
// CXX: back = static_cast<
// CXX: pd = reinterpret_cast<

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
