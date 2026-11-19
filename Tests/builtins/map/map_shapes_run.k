// Entries other than two words: values of 1, 3 and 48 bytes, and values
// aligned to 16 and 64. The entry array starts aligned in every block, and
// the bytes survive growth, swap and shift removal, reserve and shrink.

import std::io
import self::inputs::table_peek::*

var failures: u64 = 0

fn ck(cond: bool, const what: string) {
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

struct P3 {
    pub var a: u8
    pub var b: u8
    pub var c: u8
}

struct W48 {
    pub var x: [u64; 6]
}

struct A16 {
    pub var lo: u128
}

struct A64 {
    @align(64) pub var v: u64
}

macro shape!(name, V, make, ok) {
    {
        var m: {u64: V}
        for var i: u64 = 0; i < 3000; i += 1 { m.insert(i * 7919, make) }
        m.swap_remove(5 * 7919)
        m.shift_remove(0)
        m.reserve(20000)
        for var i: u64 = 1; i < 1500; i += 1 { m.swap_remove(i * 7919 * 2) }
        m.shrink_to_fit()
        var bad: u64 = 0
        for (k, *v) in m {
            var i = k / 7919
            unsafe {
                if (v as unsafe *u8 as usize) % alignof V != 0 { bad += 1 }
            }
            if !(ok) { bad += 1 }
        }
        ck(bad == 0 && tp_check(const &m) == 0, name)
    }
}

fn main() -> i32 {
    shape!("u8 values", u8, (i % 251) as u8, *v == (i % 251) as u8)
    shape!("3-byte values", P3, P3 { a: i as u8, b: (i >> 8) as u8, c: 7 }, v->a == i as u8 && v->b == (i >> 8) as u8 && v->c == 7)
    shape!("48-byte values", W48, W48 { x: [i, i + 1, i + 2, i + 3, i + 4, i + 5] }, v->x[0] == i && v->x[5] == i + 5)
    shape!("16-aligned values", A16, A16 { lo: (i as u128) << 64 }, v->lo == (i as u128) << 64)
    shape!("64-aligned values", A64, A64 { v: i }, v->v == i)
    io::println(f"{failures} failures")
    return failures as i32
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: 0 failures
