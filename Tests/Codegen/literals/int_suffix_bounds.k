// Every integer suffix at the edges of its type (primitives.mdx, Integers),
// compiled and printed: each maximum, each signed minimum, u64 and i64 past
// the signed-literal range, and 128-bit values that do not fit in 64 bits.
// The minimums are the hard ones: C++ reads `-L` as the negation of L in
// L's own type, so `-128i8` came out as the int 128 and the i64 / i128
// minimums as a signed overflow; the negated value is spelled whole.
// Also hex, binary and octal bodies, and `_` separators, under a suffix.

import std::io::println

fn main() -> i32 {
    println(f"{127i8} {-128i8} {255u8}")
    println(f"{32767i16} {-32768i16} {65535u16}")
    println(f"{2147483647i32} {-2147483648i32} {4294967295u32}")
    println(f"{9223372036854775807i64} {-9223372036854775808i64} {18446744073709551615u64}")
    println(f"{170141183460469231731687303715884105727i128}")
    println(f"{-170141183460469231731687303715884105728i128}")
    println(f"{340282366920938463463374607431768211455u128}")
    println(f"{18446744073709551616u128} {-18446744073709551616i128} {-10000000000000000000i128}")
    println(f"{0usize} {-1isize}")
    println(f"{0xFFu8} {0x7Fi8} {0b1010_0011u8} {0o777u16} {0xFFFF_FFFFu32} {1_000_000i64}")
    println(f"{0xFFFF_FFFF_FFFF_FFFFu64} {0x1_0000_0000_0000_0000u128}")

    // Arithmetic and comparison at the type, not at C++'s int.
    var r = 0
    var lo = -128i8
    if lo < 0i8 { r += 1 }
    if (lo as i32) == -128 { r += 2 }
    var umax = 18446744073709551615u64
    if umax == 0xFFFF_FFFF_FFFF_FFFFu64 { r += 4 }
    var imin = -9223372036854775808i64
    if imin < -9223372036854775807i64 { r += 8 }
    var wide = 18446744073709551616u128
    if (wide >> 64) == 1u128 { r += 16 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out; test $? -eq 31
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      127 -128 255
// OUT-NEXT: 32767 -32768 65535
// OUT-NEXT: 2147483647 -2147483648 4294967295
// OUT-NEXT: 9223372036854775807 -9223372036854775808 18446744073709551615
// OUT-NEXT: 170141183460469231731687303715884105727
// OUT-NEXT: -170141183460469231731687303715884105728
// OUT-NEXT: 340282366920938463463374607431768211455
// OUT-NEXT: 18446744073709551616 -18446744073709551616 -10000000000000000000
// OUT-NEXT: 0 -1
// OUT-NEXT: 255 127 163 511 4294967295 1000000
// OUT-NEXT: 18446744073709551615 18446744073709551616
