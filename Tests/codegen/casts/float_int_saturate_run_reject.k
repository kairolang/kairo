// Float to integer `as` saturates and sends NaN to 0 for f32 sources and
// for 16-bit targets too, with inputs built at run time so clang cannot
// fold them. The program exits 0 only when every case is right, at -O0 and
// -O2.

fn to_u8(x: f32) -> u8 { return x as u8 }
fn to_i16(x: f32) -> i16 { return x as i16 }
fn to_u16(x: f64) -> u16 { return x as u16 }
fn to_i32(x: f32) -> i32 { return x as i32 }

fn main(argc: i32) -> i32 {
    var one: f32 = argc as f32
    var zero: f32 = (argc - 1) as f32
    var nan = zero / zero
    var inf = one / zero
    if to_u8(nan) != 0 { return 1 }
    if to_u8(300.0 * one) != 255 { return 2 }
    if to_u8(-5.0 * one) != 0 { return 3 }
    if to_u8(inf) != 255 { return 4 }
    if to_i16(1000000000.0 * one) != 32767 { return 5 }
    if to_i16(-1000000000.0 * one) != -32768 { return 6 }
    if to_i16(nan) != 0 { return 7 }
    if to_u16(-1.5 * one as f64) != 0 { return 8 }
    if to_u16(70000.0 * one as f64) != 65535 { return 9 }
    if to_i32(inf) != 2147483647 { return 10 }
    if to_i32(-inf) != -2147483648 { return 11 }
    if to_i32(-2.9 * one) != -2 { return 12 }
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -w -O0 -o %t.exe --cache-dir %t.d0
// RUN: %t.exe
// RUN: rm -f %t.exe
// RUN: %kairo %s -w -O2 -o %t.exe --cache-dir %t.d2
// RUN: %t.exe
