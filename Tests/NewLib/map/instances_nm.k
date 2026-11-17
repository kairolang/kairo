// Maps over ten (key, value) pairs and sets over three element types share
// one copy of the table core: growth, linking on a full table, every
// removal form, shrink and release are not generic, so each is one symbol
// in the program however many map types it has.

struct P3 {
    pub var a: u8
    pub var b: u8
    pub var c: u8
}

struct W48 {
    pub var x: [u64; 6]
}

macro exercise!(m, k, v, j) {
    m.insert(k, v)
    m.swap_remove(j)
    m.shift_remove(j)
    m.pop()
    m.reserve(100)
    m.shrink_to_fit()
}

fn main() -> i32 {
    var m1: {u64: u64}
    exercise!(m1, 1, 2, 3)
    var m2: {u32: u8}
    exercise!(m2, 1, 2, 3)
    var m3: {i64: P3}
    exercise!(m3, 1, P3 { a: 1, b: 2, c: 3 }, 2)
    var m4: {u8: W48}
    exercise!(m4, 1, W48 { x: [1, 2, 3, 4, 5, 6] }, 2)
    var m5: {u16: f64}
    exercise!(m5, 1, 2.5, 3)
    var m6: {string: u64}
    exercise!(m6, "a", 1, "b")
    var m7: {u64: string}
    exercise!(m7, 1, "x", 2)
    var m8: {i32: bool}
    exercise!(m8, 1, true, 2)
    var m9: {usize: i16}
    exercise!(m9, 1, 2, 3)
    var m10: {i8: u64}
    exercise!(m10, 1, 1, 2)
    var s1: {u64}
    s1.insert(1)
    s1.swap_remove(1)
    var s2: {string}
    s2.insert("a")
    s2.shift_remove("a")
    var s3: {u32}
    s3.insert(1)
    s3.pop()
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// REQUIRES: llvm-nm
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -O2 --target=x86_64-linux-gnu -o %t.exe --cache-dir %t.d
// Each core member is defined once.
// RUN: %nm --defined-only %t.exe | grep -c 'RawTable4growE' | %FileCheck %s --check-prefix=ONE
// RUN: %nm --defined-only %t.exe | grep -c 'RawTable10claim_grow' | %FileCheck %s --check-prefix=ONE
// RUN: %nm --defined-only %t.exe | grep -c 'RawTable20index_unlink_swap_at' | %FileCheck %s --check-prefix=ONE
// RUN: %nm --defined-only %t.exe | grep -c 'RawTable18index_unlink_shift' | %FileCheck %s --check-prefix=ONE
// RUN: %nm --defined-only %t.exe | grep -c 'RawTable12unlink_shift' | %FileCheck %s --check-prefix=ONE
// RUN: %nm --defined-only %t.exe | grep -c 'RawTable17index_unlink_last' | %FileCheck %s --check-prefix=ONE
// RUN: %nm --defined-only %t.exe | grep -c 'RawTable6shrink' | %FileCheck %s --check-prefix=ONE
// RUN: %nm --defined-only %t.exe | grep -c 'RawTable7release' | %FileCheck %s --check-prefix=ONE
// RUN: %nm --defined-only %t.exe | grep -c 'RawTable7reserve' | %FileCheck %s --check-prefix=ONE
// ONE: {{^}}1{{$}}
