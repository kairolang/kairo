// char (a 32-bit Unicode scalar) converts implicitly to and from an integer
// only when the TARGET is equal or wider. Decided 2026-11-04.
//   implicit:  char -> u32 u64 u128 i64 i128;  u8 u16 u32 -> char
//   explicit:  char -> u8 u16 i8 i16 i32 usize isize;  i8 i16 i32 i64 i128
//              u64 u128 usize isize -> char
// An untyped integer literal takes char when it is a scalar value (0..=0xD7FF,
// 0xE000..=0x10FFFF), else SC075E.
//


fn s_u32(x: u32) {}
fn s_u64(x: u64) {}
fn s_u128(x: u128) {}
fn s_i64(x: i64) {}
fn s_i128(x: i128) {}
fn s_u8(x: u8) {}
fn s_u16(x: u16) {}
fn s_i8(x: i8) {}
fn s_i16(x: i16) {}
fn s_i32(x: i32) {}
fn s_usize(x: usize) {}
fn s_char(x: char) {}

fn ok(c: char, a: u8, b: u16, d: u32) {
    var w1: u32 = c;
    var w2: u64 = c;
    var w3: u128 = c;
    var w4: i64 = c;
    var w5: i128 = c;
    s_u32(c); s_u64(c); s_u128(c); s_i64(c); s_i128(c);
    var n1: char = a;
    var n2: char = b;
    var n3: char = d;
    s_char(a); s_char(b); s_char(d);
    var e1 = c as u8;
    var e2 = c as i32;
    var e3 = 65i32 as char;
}

fn bad_from_char(c: char) {
    var x1: u8 = c;
    var x2: u16 = c;
    var x3: i8 = c;
    var x4: i16 = c;
    var x5: i32 = c;
    var x6: usize = c;
    s_i32(c);
}

fn bad_to_char(a: i8, b: i16, c: i32, d: i64, e: u64, f: u128, g: usize) {
    var y1: char = a;
    var y2: char = b;
    var y3: char = c;
    var y4: char = d;
    var y5: char = e;
    var y6: char = f;
    var y7: char = g;
    s_char(c);
}

fn lits() {
    var l1: char = 0x41;
    var l2: char = 0xD7FF;
    var l3: char = 0xE000;
    var l4: char = 0x10FFFF;
    var bad1: char = 0xD800;
    var bad2: char = 0xDFFF;
    var bad3: char = 0x110000;
    var bad4: char = -1;
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only --cmax-errors=0 %s 2>&1 || true; } | %FileCheck %s --check-prefix=E --implicit-check-not='error ['
// E: char_integer_implicit.k:41:{{.*}}error [SC028E]: cannot convert 'char' to 'u8'{{.*}}'as'
// E: char_integer_implicit.k:42:{{.*}}error [SC028E]: cannot convert 'char' to 'u16'{{.*}}'as'
// E: char_integer_implicit.k:43:{{.*}}error [SC028E]: cannot convert 'char' to 'i8'{{.*}}'as'
// E: char_integer_implicit.k:44:{{.*}}error [SC028E]: cannot convert 'char' to 'i16'{{.*}}'as'
// E: char_integer_implicit.k:45:{{.*}}error [SC028E]: cannot convert 'char' to 'i32'{{.*}}'as'
// E: char_integer_implicit.k:46:{{.*}}error [SC028E]: cannot convert 'char' to 'usize'{{.*}}'as'
// E: char_integer_implicit.k:47:{{.*}}error [SC063E]
// E: char_integer_implicit.k:51:{{.*}}error [SC028E]: cannot convert 'i8' to 'char'{{.*}}'as'
// E: char_integer_implicit.k:52:{{.*}}error [SC028E]: cannot convert 'i16' to 'char'{{.*}}'as'
// E: char_integer_implicit.k:53:{{.*}}error [SC028E]: cannot convert 'i32' to 'char'{{.*}}'as'
// E: char_integer_implicit.k:54:{{.*}}error [SC028E]: cannot convert 'i64' to 'char'{{.*}}'as'
// E: char_integer_implicit.k:55:{{.*}}error [SC028E]: cannot convert 'u64' to 'char'{{.*}}'as'
// E: char_integer_implicit.k:56:{{.*}}error [SC028E]: cannot convert 'u128' to 'char'{{.*}}'as'
// E: char_integer_implicit.k:57:{{.*}}error [SC028E]: cannot convert 'usize' to 'char'{{.*}}'as'
// E: char_integer_implicit.k:58:{{.*}}error [SC063E]
// E: char_integer_implicit.k:66:{{.*}}error [SC075E]: literal '55296'
// E: char_integer_implicit.k:67:{{.*}}error [SC075E]: literal '57343'
// E: char_integer_implicit.k:68:{{.*}}error [SC075E]: literal '1114112'
// E: char_integer_implicit.k:69:{{.*}}error [SC075E]: literal '1'
