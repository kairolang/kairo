// Explicit integer-side conversions at their edge values, run (casting.mdx,
// conversion-lattice.mdx s3/s4, primitives.mdx). The matrix files prove
// which casts type-check; this proves what the allowed ones COMPUTE:
//
//   - narrowing keeps the low bits and never panics (casting.mdx, Narrowing);
//   - same-width signed <-> unsigned reinterprets the bits (Signed/unsigned);
//   - widening sign-extends a signed source and zero-extends an unsigned one;
//   - int -> bool is `!= 0` (lattice s4 bool), not a truncation: 256 is true;
//     bool -> int is 0 or 1;
//   - char <-> integers by code point, truncating like any narrowing;
//   - byte <-> integers by its bits; byte is unsigned (primitives.mdx Byte);
//   - c_char <-> integers: round trips through u8 and i8 hold on every
//     target; its own signedness is the target's, so c_char -> i32 of a byte
//     above 127 is checked as "either reading" and nothing more.
//
// usize/isize are checked through their own all-ones value, never a 64-bit
// literal, so the test means the same on a 32-bit target. Every value goes
// through an id_ call so the casts are runtime conversions at -O0. A failing
// check prints its label; the program's output must be exactly "bad 0".

import std::c_char
import std::io::println

fn id_i8(x: i8) -> i8 { return x; }
fn id_i32(x: i32) -> i32 { return x; }
fn id_i64(x: i64) -> i64 { return x; }
fn id_i128(x: i128) -> i128 { return x; }
fn id_u8(x: u8) -> u8 { return x; }
fn id_u32(x: u32) -> u32 { return x; }
fn id_u64(x: u64) -> u64 { return x; }
fn id_u128(x: u128) -> u128 { return x; }
fn id_char(x: char) -> char { return x; }
fn id_bool(x: bool) -> bool { return x; }

fn main() -> i32 {
    var bad = 0;

    // --- narrowing: the low bits ---------------------------------------------
    if (id_i64(1000) as i8) != -24 { println("i64 1000 as i8"); bad += 1; }
    if (id_u32(0xDEADBEEF) as u8) != 0xEF { println("u32 0xDEADBEEF as u8"); bad += 1; }
    if (id_i32(-2147483648) as i16) != 0 { println("i32 min as i16"); bad += 1; }
    if (id_i64(9223372036854775807) as i32) != -1 { println("i64 max as i32"); bad += 1; }
    if (id_u64(18446744073709551615) as u16) != 65535 { println("u64 max as u16"); bad += 1; }
    if (id_i32(-129) as i8) != 127 { println("i32 -129 as i8"); bad += 1; }

    // --- same width, other sign: the bits ----------------------------------------
    if (id_i8(-1) as u8) != 255 { println("i8 -1 as u8"); bad += 1; }
    if (id_u8(255) as i8) != -1 { println("u8 255 as i8"); bad += 1; }
    if (id_u64(18446744073709551615) as i64) != -1 { println("u64 max as i64"); bad += 1; }
    if (id_i32(-2147483648) as u32) != 2147483648 { println("i32 min as u32"); bad += 1; }

    // --- widening across sign: -1 fills every bit ---------------------------------
    if (id_i8(-1) as u64) != 18446744073709551615 { println("i8 -1 as u64"); bad += 1; }
    if (id_i8(-128) as i64) != -128 { println("i8 -128 as i64"); bad += 1; }
    if (id_u8(200) as i32) != 200 { println("u8 200 as i32"); bad += 1; }

    // --- 128-bit ---------------------------------------------------------------
    var all128 = id_i128(-1) as u128;
    if (all128 as u64) != 18446744073709551615 { println("i128 -1 as u128, low half"); bad += 1; }
    if ((all128 >> 64) as u64) != 18446744073709551615 { println("i128 -1 as u128, high half"); bad += 1; }
    if (id_u128(18446744073709551621) as u64) != 5 { println("u128 2^64+5 as u64"); bad += 1; }
    if (id_i128(-2) as i8) != -2 { println("i128 -2 as i8"); bad += 1; }
    if (id_i64(-5) as i128) != -5 { println("i64 -5 as i128"); bad += 1; }

    // --- usize / isize, through their own all-ones value ----------------------------
    var umax = id_i32(-1) as usize;
    if (umax + 1) != 0 { println("i32 -1 as usize is all ones"); bad += 1; }
    if (umax as isize) != -1 { println("usize max as isize"); bad += 1; }
    if (umax as u8) != 255 { println("usize max as u8"); bad += 1; }
    if ((id_i8(-3) as isize) as i8) != -3 { println("i8 -3 via isize"); bad += 1; }

    // --- bool: != 0 one way, 0/1 the other -------------------------------------------
    if (id_i32(256) as bool) != true { println("i32 256 as bool"); bad += 1; }
    if (id_i32(-1) as bool) != true { println("i32 -1 as bool"); bad += 1; }
    if (id_i32(0) as bool) != false { println("i32 0 as bool"); bad += 1; }
    if (id_u128(18446744073709551616) as bool) != true { println("u128 2^64 as bool"); bad += 1; }
    if (id_bool(true) as i32) != 1 { println("true as i32"); bad += 1; }
    if (id_bool(false) as u8) != 0 { println("false as u8"); bad += 1; }
    if (id_bool(true) as i128) != 1 { println("true as i128"); bad += 1; }
    if ((id_i32(2) as bool) as i32) != 1 { println("i32 2 as bool as i32"); bad += 1; }

    // --- char: the code point ---------------------------------------------------
    if (id_char('A') as u32) != 65 { println("'A' as u32"); bad += 1; }
    if (id_u32(65) as char) != 'A' { println("u32 65 as char"); bad += 1; }
    // Non-ASCII code points come from integers: a non-ASCII char LITERAL
    // does not build today (xfail_char_literal_non_ascii.k).
    var han = id_u32(0x6F22) as char;
    if (han as u32) != 0x6F22 { println("U+6F22 as u32"); bad += 1; }
    if (han as u8) != 0x22 { println("U+6F22 as u8 truncates"); bad += 1; }
    if (han as i16) != 0x6F22 { println("U+6F22 as i16"); bad += 1; }
    if ((id_u32(0xE9) as char) as i8) != -23 { println("U+00E9 as i8"); bad += 1; }
    if (id_i64(0x10FFFF) as char as u32) != 0x10FFFF { println("max scalar round trip"); bad += 1; }

    // --- byte: its bits, unsigned --------------------------------------------------
    var bf = id_u8(0xF0) as byte;
    if (bf as u8) != 240 { println("u8 0xF0 as byte as u8"); bad += 1; }
    if (bf as i32) != 240 { println("byte 0xF0 as i32 zero-extends"); bad += 1; }
    if (bf as i8) != -16 { println("byte 0xF0 as i8"); bad += 1; }
    if ((id_i32(-1) as byte) as u8) != 255 { println("i32 -1 as byte"); bad += 1; }
    if ((id_i32(0x1FF) as byte) as u8) != 255 { println("i32 0x1FF as byte truncates"); bad += 1; }

    // --- c_char: the byte survives; the sign is the target's ------------------------
    if ((id_u8(200) as c_char) as u8) != 200 { println("u8 200 via c_char"); bad += 1; }
    if ((id_i8(-1) as c_char) as i8) != -1 { println("i8 -1 via c_char"); bad += 1; }
    var ca: c_char = 65;
    if (ca as i32) != 65 { println("c_char 65 as i32"); bad += 1; }
    var hi = (id_u8(200) as c_char) as i32;
    if (hi != 200) && (hi != -56) { println("c_char 200 as i32 is neither reading"); bad += 1; }

    println(f"bad {bad}");
    return bad;
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: bad 0
