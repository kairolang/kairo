// P104, P223 in use: a raw pointer walks an array to its end with `<`, an
// offset of any integer type and sign scales by the pointee (a 12-byte
// struct moves 12 bytes per step), and the same arithmetic types inside a
// generic body, where T's size is only known per instance.

struct Trio { var a: i32; var b: i32; var c: i32 }

fn <T> nth(p: unsafe *T, n: usize) -> unsafe *T { return p + n }
fn <T> span(lo: unsafe *T, hi: unsafe *T) -> isize { return hi - lo }

fn main() -> i32 {
    var arr: [i32; 8] = [1, 2, 3, 4, 5, 6, 7, 8]
    var trios: [Trio; 3] = [Trio{ a: 1, b: 2, c: 3 }, Trio{ a: 4, b: 5, c: 6 }, Trio{ a: 7, b: 8, c: 9 }]
    var p: unsafe *i32 = &null
    var t: unsafe *Trio = &null
    unsafe {
        p = &arr[0] as unsafe *i32
        t = &trios[0] as unsafe *Trio
    }

    // Walk to one past the end.
    var unsafe *end = p + 8
    var unsafe *cur = p
    var sum = 0
    while cur < end {
        unsafe { sum += *cur }
        cur += 1
    }
    if sum != 36 { return 1 }
    if cur != end { return 2 }

    // Offsets of other integer types and signs.
    var unsafe *mid = p + 5u8
    var unsafe *back = mid + (-2)
    var unsafe *back2 = mid - 2i64
    unsafe {
        if *back != 4 { return 3 }
        if *back2 != 4 { return 4 }
    }
    if back != back2 { return 5 }

    // Scaled by the pointee: Trio is 12 bytes.
    var unsafe *t2 = t + 2
    var bytes: usize = 0
    unsafe {
        if t2->a != 7 { return 6 }
        bytes = (t2 as usize) - (t as usize)
    }
    if bytes != 24 { return 7 }

    // Generic bodies.
    var unsafe *g = nth(p, 7)
    unsafe { if *g != 8 { return 8 } }
    if span(p, end) != 8 { return 9 }
    if span(t, t2) != 2 { return 10 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
