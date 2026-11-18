// The saturating float-to-integer `as` from every native float width, in a
// constant and through `eval`: an f32 bound that is exact (2^31), a bound past
// the source type's range (2^128 from f32), which only the infinity reaches,
// f16 and bf16 (widened to f32 first), a bf16 call result in particular,
// pointer-width and nullable targets, and compile-time casts, which give
// the same answers as run-time ones (C++ would reject `1e30 as i32` in a
// constant expression as out of range).
import std::io

fn f32_i32(x: f32) -> i32 { return x as i32 }
fn f32_u128(x: f32) -> u128 { return x as u128 }
fn f16_u16(x: f16) -> u16 { return x as u16 }
fn f16_i8(x: f16) -> i8 { return x as i8 }
fn f64_usize(x: f64) -> usize { return x as usize }
fn f64_isize(x: f64) -> isize { return x as isize }
fn id_bf16(x: bf16) -> bf16 { return x }
fn f64_opt_i32(x: f64) -> i32? { return x as i32? }

eval BIG: i32 = 1.0e30 as i32
eval NEG: u8 = -3.5 as u8
eval TRUNC: i16 = -7.9 as i16

fn main(argc: i32) -> i32 {
    var one   = ((argc + 99) / 100) as f32
    var zero  = (argc / 100) as f32
    var h1    = ((argc + 99) / 100) as f16
    var h0    = (argc / 100) as f16
    var d1    = ((argc + 99) / 100) as f64
    io::println(f"f32_i32 {f32_i32(2147483648.0f32 * one)} {f32_i32(2147483520.0f32 * one)} {f32_i32(-2147483648.0f32 * one)} {f32_i32(zero / zero)}")
    io::println(f"f32_u128 {f32_u128(one / zero)} {f32_u128(3.4028235e38f32 * one)} {f32_u128(-one / zero)}")
    io::println(f"f16_u16 {f16_u16(65504.0f16 * h1)} {f16_u16(h1 / h0)} {f16_u16(-2.0f16 * h1)}")
    io::println(f"f16_i8 {f16_i8(200.0f16 * h1)} {f16_i8(-200.0f16 * h1)} {f16_i8(-7.5f16 * h1)}")
    io::println(f"f64_usize {f64_usize(-1.0 * d1)} {f64_usize(1.0e30 * d1)} {f64_isize(-1.0e30 * d1)}")
    io::println(f"bf16 {id_bf16(7.5bf16) as u8} {id_bf16(-300.0bf16) as i8} {id_bf16(300.0bf16) as u8}")
    io::println(f"opt {f64_opt_i32(1.0e30 * d1) ?? 0} {f64_opt_i32(-7.9 * d1) ?? 0}")
    io::println(f"eval {BIG} {NEG} {TRUNC}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// The cast is a lambda called on the operand: evaluated once, and a constant
// expression.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: BIG ={{ ?}}[](double __kairo_fx) noexcept{{ ?}}->{{ ?}}signed int {
// CXX-DAG: return __kairo_fx != __kairo_fx ? static_cast<signed int>(0):{{ ?}}__kairo_fx >= static_cast<float>(0x1p31) ? static_cast<signed int>(~static_cast<signed int>(-{{ ?}}0x1p31)):{{ ?}}__kairo_fx <= -{{ ?}}static_cast<float>(0x1p31) ? static_cast<signed int>(-{{ ?}}0x1p31):{{ ?}}static_cast<signed int>(__kairo_fx);
// CXX-DAG: __kairo_fx >= static_cast<float>(__builtin_inf()) ? static_cast<unsigned __int128>(-{{ ?}}1)

// REQUIRES: clang
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d/o2
// RUN: %t.o2.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT: f32_i32 2147483647 2147483520 -2147483648 0
// OUT-NEXT: f32_u128 340282366920938463463374607431768211455 340282346638528859811704183484516925440 0
// OUT-NEXT: f16_u16 65504 65535 0
// OUT-NEXT: f16_i8 127 -128 -7
// OUT-NEXT: f64_usize 0 18446744073709551615 -9223372036854775808
// OUT-NEXT: bf16 7 -128 255
// OUT-NEXT: opt 2147483647 -7
// OUT-NEXT: eval 2147483647 0 -7
