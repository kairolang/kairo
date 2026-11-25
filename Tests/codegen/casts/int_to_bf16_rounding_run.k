// An integer `as` bf16 rounds once, to nearest even, from every integer
// width (casting.mdx, "Integer to float"): a value just past a midpoint goes
// up even when the bit that puts it there is far below f32's 24-bit
// significand, an exact midpoint goes to the even neighbour, and a magnitude
// past bf16's range is infinity. The inputs are computed from argc, so clang
// cannot fold them; the `eval` constant gets the same answer as the run.
// Each line prints the bf16's bits.
import std::io

fn bits(x: bf16) -> u16 { return x.to_bits() }

eval E_UP: bf16 = (1073741824 + 4194304 + 1) as i64 as bf16

fn main(argc: i32) -> i32 {
    var o32: i32    = (argc + 99) / 100
    var u32o: u32   = o32 as u32
    var o64: i64    = o32 as i64
    var u64o: u64   = o32 as u64
    var o128: i128  = o32 as i128
    var u128o: u128 = o32 as u128
    var o256: i256  = o32 as i256
    var u512o: u512 = o32 as u512
    var osz: isize  = o32 as isize

    // 2^30 + 2^22 + 1: one past the midpoint between 2^30 and 2^30 + 2^23.
    var up: i32   = 1073741824 + 4194304 + 1
    var tie: i32  = 1073741824 + 4194304
    var tie3: i32 = 1073741824 + 3 * 4194304
    var below: i32 = 1073741824 + 4194304 - 1
    var up32: u32 = 3221225472 + 8388608 + 1
    io::println(f"i32_up {bits((up * o32) as bf16)}")
    io::println(f"i32_tie_even {bits((tie * o32) as bf16)}")
    io::println(f"i32_tie_up {bits((tie3 * o32) as bf16)}")
    io::println(f"i32_below {bits((below * o32) as bf16)}")
    io::println(f"i32_neg {bits((-up * o32) as bf16)}")
    io::println(f"u32_up {bits((up32 * u32o) as bf16)}")
    io::println(f"i64_up {bits((4629700416936869889 * o64) as bf16)}")
    var m64: u64 = 18446744073709551615
    io::println(f"u64_max {bits((m64 * u64o) as bf16)}")
    io::println(f"i128_far {bits((1272602360385370922596299702273 * o128) as bf16)}")
    var mn: i128 = -170141183460469231731687303715884105727 - 1
    io::println(f"i128_min {bits((mn * o128) as bf16)}")
    var mx: u128 = 340282366920938463463374607431768211455
    io::println(f"u128_max {bits((mx * u128o) as bf16)}")
    var far: i256 = 1334420292643450700532337556609564673
    io::println(f"i256_far {bits((-far * o256) as bf16)}")
    io::println(f"u512_big {bits((u512o << 200) as bf16)}")
    io::println(f"isize_up {bits(((up as isize) * osz) as bf16)}")
    var nb = ((4629700416936869889 * o64) as bf16?) ?? (0 as bf16)
    io::println(f"nullable {bits(nb)}")
    io::println(f"eval {bits(E_UP)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s
// CHECK: i32_up 20097
// CHECK-NEXT: i32_tie_even 20096
// CHECK-NEXT: i32_tie_up 20098
// CHECK-NEXT: i32_below 20096
// CHECK-NEXT: i32_neg 52865
// CHECK-NEXT: u32_up 20289
// CHECK-NEXT: i64_up 24193
// CHECK-NEXT: u64_max 24448
// CHECK-NEXT: i128_far 29057
// CHECK-NEXT: i128_min 65280
// CHECK-NEXT: u128_max 32640
// CHECK-NEXT: i256_far 64385
// CHECK-NEXT: u512_big 32640
// CHECK-NEXT: isize_up 20097
// CHECK-NEXT: nullable 24193
// CHECK-NEXT: eval 20097
