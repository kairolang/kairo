// A float `as` an integer truncates toward zero and saturates: NaN is 0, a
// value at or past the target's maximum is the maximum, at or past its
// minimum the minimum, and the infinities likewise (casting.mdx, "Float to
// integer"; conversion-lattice.mdx: never undefined behavior). Each target is
// fed NaN, both infinities, 1e30, -1e30, -1.0, -0.5, 0.99, and the doubles just
// inside, exactly at, and just past each bound. The inputs are computed from
// argc, so clang cannot fold them, and the same answers come out at -O0 and
// -O2.
import std::io

fn to_i8(x: f64) -> i8 { return x as i8 }
fn to_u8(x: f64) -> u8 { return x as u8 }
fn to_i32(x: f64) -> i32 { return x as i32 }
fn to_u32(x: f64) -> u32 { return x as u32 }
fn to_i64(x: f64) -> i64 { return x as i64 }
fn to_u64(x: f64) -> u64 { return x as u64 }
fn to_i128(x: f64) -> i128 { return x as i128 }
fn to_u128(x: f64) -> u128 { return x as u128 }

fn main(argc: i32) -> i32 {
    var zero = (argc / 100) as f64
    var one  = ((argc + 99) / 100) as f64
    var nan  = zero / zero
    var inf  = one / zero
    io::println(f"i8 nan {to_i8(nan)}")
    io::println(f"i8 +inf {to_i8(inf)}")
    io::println(f"i8 -inf {to_i8(-inf)}")
    io::println(f"i8 1e30 {to_i8(1000000000000000019884624838656.0 * one)}")
    io::println(f"i8 -1e30 {to_i8(-1000000000000000019884624838656.0 * one)}")
    io::println(f"i8 -1.0 {to_i8(-1.0 * one)}")
    io::println(f"i8 -0.5 {to_i8(-0.5 * one)}")
    io::println(f"i8 0.99 {to_i8(0.99 * one)}")
    io::println(f"i8 hi_in {to_i8(127.99999999999999 * one)}")
    io::println(f"i8 hi_at {to_i8(128.0 * one)}")
    io::println(f"i8 hi_out {to_i8(128.00000000000003 * one)}")
    io::println(f"i8 lo_in {to_i8(-127.99999999999999 * one)}")
    io::println(f"i8 lo_at {to_i8(-128.0 * one)}")
    io::println(f"i8 lo_out {to_i8(-128.00000000000003 * one)}")
    io::println(f"u8 nan {to_u8(nan)}")
    io::println(f"u8 +inf {to_u8(inf)}")
    io::println(f"u8 -inf {to_u8(-inf)}")
    io::println(f"u8 1e30 {to_u8(1000000000000000019884624838656.0 * one)}")
    io::println(f"u8 -1e30 {to_u8(-1000000000000000019884624838656.0 * one)}")
    io::println(f"u8 -1.0 {to_u8(-1.0 * one)}")
    io::println(f"u8 -0.5 {to_u8(-0.5 * one)}")
    io::println(f"u8 0.99 {to_u8(0.99 * one)}")
    io::println(f"u8 hi_in {to_u8(255.99999999999997 * one)}")
    io::println(f"u8 hi_at {to_u8(256.0 * one)}")
    io::println(f"u8 hi_out {to_u8(256.00000000000006 * one)}")
    io::println(f"i32 nan {to_i32(nan)}")
    io::println(f"i32 +inf {to_i32(inf)}")
    io::println(f"i32 -inf {to_i32(-inf)}")
    io::println(f"i32 1e30 {to_i32(1000000000000000019884624838656.0 * one)}")
    io::println(f"i32 -1e30 {to_i32(-1000000000000000019884624838656.0 * one)}")
    io::println(f"i32 -1.0 {to_i32(-1.0 * one)}")
    io::println(f"i32 -0.5 {to_i32(-0.5 * one)}")
    io::println(f"i32 0.99 {to_i32(0.99 * one)}")
    io::println(f"i32 hi_in {to_i32(2147483647.9999998 * one)}")
    io::println(f"i32 hi_at {to_i32(2147483648.0 * one)}")
    io::println(f"i32 hi_out {to_i32(2147483648.0000005 * one)}")
    io::println(f"i32 lo_in {to_i32(-2147483647.9999998 * one)}")
    io::println(f"i32 lo_at {to_i32(-2147483648.0 * one)}")
    io::println(f"i32 lo_out {to_i32(-2147483648.0000005 * one)}")
    io::println(f"u32 nan {to_u32(nan)}")
    io::println(f"u32 +inf {to_u32(inf)}")
    io::println(f"u32 -inf {to_u32(-inf)}")
    io::println(f"u32 1e30 {to_u32(1000000000000000019884624838656.0 * one)}")
    io::println(f"u32 -1e30 {to_u32(-1000000000000000019884624838656.0 * one)}")
    io::println(f"u32 -1.0 {to_u32(-1.0 * one)}")
    io::println(f"u32 -0.5 {to_u32(-0.5 * one)}")
    io::println(f"u32 0.99 {to_u32(0.99 * one)}")
    io::println(f"u32 hi_in {to_u32(4294967295.9999995 * one)}")
    io::println(f"u32 hi_at {to_u32(4294967296.0 * one)}")
    io::println(f"u32 hi_out {to_u32(4294967296.000001 * one)}")
    io::println(f"i64 nan {to_i64(nan)}")
    io::println(f"i64 +inf {to_i64(inf)}")
    io::println(f"i64 -inf {to_i64(-inf)}")
    io::println(f"i64 1e30 {to_i64(1000000000000000019884624838656.0 * one)}")
    io::println(f"i64 -1e30 {to_i64(-1000000000000000019884624838656.0 * one)}")
    io::println(f"i64 -1.0 {to_i64(-1.0 * one)}")
    io::println(f"i64 -0.5 {to_i64(-0.5 * one)}")
    io::println(f"i64 0.99 {to_i64(0.99 * one)}")
    io::println(f"i64 hi_in {to_i64(9223372036854774784.0 * one)}")
    io::println(f"i64 hi_at {to_i64(9223372036854775808.0 * one)}")
    io::println(f"i64 hi_out {to_i64(9223372036854777856.0 * one)}")
    io::println(f"i64 lo_in {to_i64(-9223372036854774784.0 * one)}")
    io::println(f"i64 lo_at {to_i64(-9223372036854775808.0 * one)}")
    io::println(f"i64 lo_out {to_i64(-9223372036854777856.0 * one)}")
    io::println(f"u64 nan {to_u64(nan)}")
    io::println(f"u64 +inf {to_u64(inf)}")
    io::println(f"u64 -inf {to_u64(-inf)}")
    io::println(f"u64 1e30 {to_u64(1000000000000000019884624838656.0 * one)}")
    io::println(f"u64 -1e30 {to_u64(-1000000000000000019884624838656.0 * one)}")
    io::println(f"u64 -1.0 {to_u64(-1.0 * one)}")
    io::println(f"u64 -0.5 {to_u64(-0.5 * one)}")
    io::println(f"u64 0.99 {to_u64(0.99 * one)}")
    io::println(f"u64 hi_in {to_u64(18446744073709549568.0 * one)}")
    io::println(f"u64 hi_at {to_u64(18446744073709551616.0 * one)}")
    io::println(f"u64 hi_out {to_u64(18446744073709555712.0 * one)}")
    io::println(f"i128 nan {to_i128(nan)}")
    io::println(f"i128 +inf {to_i128(inf)}")
    io::println(f"i128 -inf {to_i128(-inf)}")
    io::println(f"i128 1e30 {to_i128(1000000000000000019884624838656.0 * one)}")
    io::println(f"i128 -1e30 {to_i128(-1000000000000000019884624838656.0 * one)}")
    io::println(f"i128 -1.0 {to_i128(-1.0 * one)}")
    io::println(f"i128 -0.5 {to_i128(-0.5 * one)}")
    io::println(f"i128 0.99 {to_i128(0.99 * one)}")
    io::println(f"i128 hi_in {to_i128(170141183460469212842221372237303250944.0 * one)}")
    io::println(f"i128 hi_at {to_i128(170141183460469231731687303715884105728.0 * one)}")
    io::println(f"i128 hi_out {to_i128(170141183460469269510619166673045815296.0 * one)}")
    io::println(f"i128 lo_in {to_i128(-170141183460469212842221372237303250944.0 * one)}")
    io::println(f"i128 lo_at {to_i128(-170141183460469231731687303715884105728.0 * one)}")
    io::println(f"i128 lo_out {to_i128(-170141183460469269510619166673045815296.0 * one)}")
    io::println(f"u128 nan {to_u128(nan)}")
    io::println(f"u128 +inf {to_u128(inf)}")
    io::println(f"u128 -inf {to_u128(-inf)}")
    io::println(f"u128 1e30 {to_u128(1000000000000000019884624838656.0 * one)}")
    io::println(f"u128 -1e30 {to_u128(-1000000000000000019884624838656.0 * one)}")
    io::println(f"u128 -1.0 {to_u128(-1.0 * one)}")
    io::println(f"u128 -0.5 {to_u128(-0.5 * one)}")
    io::println(f"u128 0.99 {to_u128(0.99 * one)}")
    io::println(f"u128 hi_in {to_u128(340282366920938425684442744474606501888.0 * one)}")
    io::println(f"u128 hi_at {to_u128(340282366920938463463374607431768211456.0 * one)}")
    io::println(f"u128 hi_out {to_u128(340282366920938539021238333346091630592.0 * one)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d/o2
// RUN: %t.o2.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT: i8 nan 0
// OUT-NEXT: i8 +inf 127
// OUT-NEXT: i8 -inf -128
// OUT-NEXT: i8 1e30 127
// OUT-NEXT: i8 -1e30 -128
// OUT-NEXT: i8 -1.0 -1
// OUT-NEXT: i8 -0.5 0
// OUT-NEXT: i8 0.99 0
// OUT-NEXT: i8 hi_in 127
// OUT-NEXT: i8 hi_at 127
// OUT-NEXT: i8 hi_out 127
// OUT-NEXT: i8 lo_in -127
// OUT-NEXT: i8 lo_at -128
// OUT-NEXT: i8 lo_out -128
// OUT-NEXT: u8 nan 0
// OUT-NEXT: u8 +inf 255
// OUT-NEXT: u8 -inf 0
// OUT-NEXT: u8 1e30 255
// OUT-NEXT: u8 -1e30 0
// OUT-NEXT: u8 -1.0 0
// OUT-NEXT: u8 -0.5 0
// OUT-NEXT: u8 0.99 0
// OUT-NEXT: u8 hi_in 255
// OUT-NEXT: u8 hi_at 255
// OUT-NEXT: u8 hi_out 255
// OUT-NEXT: i32 nan 0
// OUT-NEXT: i32 +inf 2147483647
// OUT-NEXT: i32 -inf -2147483648
// OUT-NEXT: i32 1e30 2147483647
// OUT-NEXT: i32 -1e30 -2147483648
// OUT-NEXT: i32 -1.0 -1
// OUT-NEXT: i32 -0.5 0
// OUT-NEXT: i32 0.99 0
// OUT-NEXT: i32 hi_in 2147483647
// OUT-NEXT: i32 hi_at 2147483647
// OUT-NEXT: i32 hi_out 2147483647
// OUT-NEXT: i32 lo_in -2147483647
// OUT-NEXT: i32 lo_at -2147483648
// OUT-NEXT: i32 lo_out -2147483648
// OUT-NEXT: u32 nan 0
// OUT-NEXT: u32 +inf 4294967295
// OUT-NEXT: u32 -inf 0
// OUT-NEXT: u32 1e30 4294967295
// OUT-NEXT: u32 -1e30 0
// OUT-NEXT: u32 -1.0 0
// OUT-NEXT: u32 -0.5 0
// OUT-NEXT: u32 0.99 0
// OUT-NEXT: u32 hi_in 4294967295
// OUT-NEXT: u32 hi_at 4294967295
// OUT-NEXT: u32 hi_out 4294967295
// OUT-NEXT: i64 nan 0
// OUT-NEXT: i64 +inf 9223372036854775807
// OUT-NEXT: i64 -inf -9223372036854775808
// OUT-NEXT: i64 1e30 9223372036854775807
// OUT-NEXT: i64 -1e30 -9223372036854775808
// OUT-NEXT: i64 -1.0 -1
// OUT-NEXT: i64 -0.5 0
// OUT-NEXT: i64 0.99 0
// OUT-NEXT: i64 hi_in 9223372036854774784
// OUT-NEXT: i64 hi_at 9223372036854775807
// OUT-NEXT: i64 hi_out 9223372036854775807
// OUT-NEXT: i64 lo_in -9223372036854774784
// OUT-NEXT: i64 lo_at -9223372036854775808
// OUT-NEXT: i64 lo_out -9223372036854775808
// OUT-NEXT: u64 nan 0
// OUT-NEXT: u64 +inf 18446744073709551615
// OUT-NEXT: u64 -inf 0
// OUT-NEXT: u64 1e30 18446744073709551615
// OUT-NEXT: u64 -1e30 0
// OUT-NEXT: u64 -1.0 0
// OUT-NEXT: u64 -0.5 0
// OUT-NEXT: u64 0.99 0
// OUT-NEXT: u64 hi_in 18446744073709549568
// OUT-NEXT: u64 hi_at 18446744073709551615
// OUT-NEXT: u64 hi_out 18446744073709551615
// OUT-NEXT: i128 nan 0
// OUT-NEXT: i128 +inf 170141183460469231731687303715884105727
// OUT-NEXT: i128 -inf -170141183460469231731687303715884105728
// OUT-NEXT: i128 1e30 1000000000000000019884624838656
// OUT-NEXT: i128 -1e30 -1000000000000000019884624838656
// OUT-NEXT: i128 -1.0 -1
// OUT-NEXT: i128 -0.5 0
// OUT-NEXT: i128 0.99 0
// OUT-NEXT: i128 hi_in 170141183460469212842221372237303250944
// OUT-NEXT: i128 hi_at 170141183460469231731687303715884105727
// OUT-NEXT: i128 hi_out 170141183460469231731687303715884105727
// OUT-NEXT: i128 lo_in -170141183460469212842221372237303250944
// OUT-NEXT: i128 lo_at -170141183460469231731687303715884105728
// OUT-NEXT: i128 lo_out -170141183460469231731687303715884105728
// OUT-NEXT: u128 nan 0
// OUT-NEXT: u128 +inf 340282366920938463463374607431768211455
// OUT-NEXT: u128 -inf 0
// OUT-NEXT: u128 1e30 1000000000000000019884624838656
// OUT-NEXT: u128 -1e30 0
// OUT-NEXT: u128 -1.0 0
// OUT-NEXT: u128 -0.5 0
// OUT-NEXT: u128 0.99 0
// OUT-NEXT: u128 hi_in 340282366920938425684442744474606501888
// OUT-NEXT: u128 hi_at 340282366920938463463374607431768211455
// OUT-NEXT: u128 hi_out 340282366920938463463374607431768211455
