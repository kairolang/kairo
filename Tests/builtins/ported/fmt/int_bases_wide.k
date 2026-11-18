// u128 and i128 in base 16, 8 and 2 with `#`, `+`, width, fill, alignment and zero padding, up to the maximum.
// Rules asserted (library docs): an integer hole prints in decimal or, with `x`, `X`, `o`, `b`, in that base; `#` adds the
// 0x / 0o / 0b prefix, `+` a sign, `0` pads with zeros after the sign and prefix, width and fill pad in code points and numbers
// default to right alignment (website library/core/formatting.mdx, FmtBuf.put_i8 .. put_u512; Lib/builtin2/fmt/fmt_buf.k
// number_). The spec grammar is the one in the comment above `_parse_spec` in Compiler/Sema/Type/LiteralTyping.k.
// Expected texts come from a Python oracle that applies those rules to exact Python integers.
// Not asserted because the docs do not state them: negative values in a base, `#X`, `#` on decimal, `0` together with an
// explicit alignment, and the split of an odd amount of padding by `^` (centred cases use an even amount).
// Cases from Rust library/coretests/tests/fmt/num.rs (test_format_int_limits, test_format_int_flags, test_format_int_sign_padding)
// Cases from Rust library/coretests/tests/fmt/mod.rs (the integer flag cases)
// Cases from the {fmt} library test/format-test.cc (integer width, fill, alignment, sign, # and 0 cases)

import std::io::*

var CODE: i32 = 0

fn ck(const got: string, const want: string, id: i32, const name: string) {
    if !(got == want) {
        println(f"FAIL {name}: got [{got}] want [{want}]")
        if CODE == 0 {
            CODE = id
        }
    }
}

fn bases_u128() {
    var v0: u128 = 0
    var v1: u128 = 1
    var v2: u128 = 255
    var v3: u128 = 18446744073709551616
    var v4: u128 = u128::MAX
    ck(f"{v0:x}", "0", 9, "u128 0 {x}")
    ck(f"{v0:X}", "0", 9, "u128 0 {X}")
    ck(f"{v0:o}", "0", 9, "u128 0 {o}")
    ck(f"{v0:b}", "0", 9, "u128 0 {b}")
    ck(f"{v0:#x}", "0x0", 9, "u128 0 {#x}")
    ck(f"{v0:#o}", "0o0", 9, "u128 0 {#o}")
    ck(f"{v0:#b}", "0b0", 9, "u128 0 {#b}")
    ck(f"{v1:x}", "1", 9, "u128 1 {x}")
    ck(f"{v1:X}", "1", 9, "u128 1 {X}")
    ck(f"{v1:o}", "1", 9, "u128 1 {o}")
    ck(f"{v1:b}", "1", 9, "u128 1 {b}")
    ck(f"{v1:#x}", "0x1", 9, "u128 1 {#x}")
    ck(f"{v1:#o}", "0o1", 9, "u128 1 {#o}")
    ck(f"{v1:#b}", "0b1", 9, "u128 1 {#b}")
    ck(f"{v2:x}", "ff", 9, "u128 255 {x}")
    ck(f"{v2:X}", "FF", 9, "u128 255 {X}")
    ck(f"{v2:o}", "377", 9, "u128 255 {o}")
    ck(f"{v2:b}", "11111111", 9, "u128 255 {b}")
    ck(f"{v2:#x}", "0xff", 9, "u128 255 {#x}")
    ck(f"{v2:#o}", "0o377", 9, "u128 255 {#o}")
    ck(f"{v2:#b}", "0b11111111", 9, "u128 255 {#b}")
    ck(f"{v2:20x}", "                  ff", 9, "u128 255 {20x}")
    ck(f"{v2:<20x}", "ff                  ", 9, "u128 255 {<20x}")
    ck(f"{v2:*>20x}", "******************ff", 9, "u128 255 {*>20x}")
    ck(f"{v2:→<20X}", "FF→→→→→→→→→→→→→→→→→→", 9, "u128 255 {→<20X}")
    ck(f"{v2:020x}", "000000000000000000ff", 9, "u128 255 {020x}")
    ck(f"{v2:#020x}", "0x0000000000000000ff", 9, "u128 255 {#020x}")
    ck(f"{v2:#030o}", "0o0000000000000000000000000377", 9, "u128 255 {#030o}")
    ck(f"{v2:#040b}", "0b00000000000000000000000000000011111111", 9, "u128 255 {#040b}")
    ck(f"{v2:日>#40b}", "日日日日日日日日日日日日日日日日日日日日日日日日日日日日日日0b11111111", 9, "u128 255 {日>#40b}")
    ck(f"{v2:😀^#24x}", "😀😀😀😀😀😀😀😀😀😀0xff😀😀😀😀😀😀😀😀😀😀", 9, "u128 255 {😀^#24x}")
    ck(f"{v2:+x}", "+ff", 9, "u128 255 {+x}")
    ck(f"{v2:+#12x}", "       +0xff", 9, "u128 255 {+#12x}")
    ck(f"{v2:+#012b}", "+0b011111111", 9, "u128 255 {+#012b}")
    ck(f"{v2:_<+12o}", "+377________", 9, "u128 255 {_<+12o}")
    ck(f"{v3:x}", "10000000000000000", 9, "u128 big {x}")
    ck(f"{v3:X}", "10000000000000000", 9, "u128 big {X}")
    ck(f"{v3:o}", "2000000000000000000000", 9, "u128 big {o}")
    ck(f"{v3:b}", "10000000000000000000000000000000000000000000000000000000000000000", 9, "u128 big {b}")
    ck(f"{v3:#x}", "0x10000000000000000", 9, "u128 big {#x}")
    ck(f"{v3:#o}", "0o2000000000000000000000", 9, "u128 big {#o}")
    ck(f"{v3:#b}", "0b10000000000000000000000000000000000000000000000000000000000000000", 9, "u128 big {#b}")
    ck(f"{v4:x}", "ffffffffffffffffffffffffffffffff", 9, "u128 big {x}")
    ck(f"{v4:X}", "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", 9, "u128 big {X}")
    ck(f"{v4:o}", "3777777777777777777777777777777777777777777", 9, "u128 big {o}")
    ck(f"{v4:b}", "11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111", 9, "u128 big {b}")
    ck(f"{v4:#x}", "0xffffffffffffffffffffffffffffffff", 9, "u128 big {#x}")
    ck(f"{v4:#o}", "0o3777777777777777777777777777777777777777777", 9, "u128 big {#o}")
    ck(f"{v4:#b}", "0b11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111", 9, "u128 big {#b}")
    ck(f"{v4:20x}", "ffffffffffffffffffffffffffffffff", 9, "u128 big {20x}")
    ck(f"{v4:<20x}", "ffffffffffffffffffffffffffffffff", 9, "u128 big {<20x}")
    ck(f"{v4:*>20x}", "ffffffffffffffffffffffffffffffff", 9, "u128 big {*>20x}")
    ck(f"{v4:→<20X}", "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", 9, "u128 big {→<20X}")
    ck(f"{v4:020x}", "ffffffffffffffffffffffffffffffff", 9, "u128 big {020x}")
    ck(f"{v4:#020x}", "0xffffffffffffffffffffffffffffffff", 9, "u128 big {#020x}")
    ck(f"{v4:#030o}", "0o3777777777777777777777777777777777777777777", 9, "u128 big {#030o}")
    ck(f"{v4:#040b}", "0b11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111", 9, "u128 big {#040b}")
    ck(f"{v4:日>#40b}", "0b11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111", 9, "u128 big {日>#40b}")
    ck(f"{v4:😀^#24x}", "0xffffffffffffffffffffffffffffffff", 9, "u128 big {😀^#24x}")
    ck(f"{v4:+x}", "+ffffffffffffffffffffffffffffffff", 9, "u128 big {+x}")
    ck(f"{v4:+#12x}", "+0xffffffffffffffffffffffffffffffff", 9, "u128 big {+#12x}")
    ck(f"{v4:+#012b}", "+0b11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111", 9, "u128 big {+#012b}")
    ck(f"{v4:_<+12o}", "+3777777777777777777777777777777777777777777", 9, "u128 big {_<+12o}")
}

fn bases_i128() {
    var v0: i128 = 0
    var v1: i128 = 1
    var v2: i128 = 255
    var v3: i128 = 18446744073709551616
    var v4: i128 = i128::MAX
    ck(f"{v0:x}", "0", 10, "i128 0 {x}")
    ck(f"{v0:X}", "0", 10, "i128 0 {X}")
    ck(f"{v0:o}", "0", 10, "i128 0 {o}")
    ck(f"{v0:b}", "0", 10, "i128 0 {b}")
    ck(f"{v0:#x}", "0x0", 10, "i128 0 {#x}")
    ck(f"{v0:#o}", "0o0", 10, "i128 0 {#o}")
    ck(f"{v0:#b}", "0b0", 10, "i128 0 {#b}")
    ck(f"{v1:x}", "1", 10, "i128 1 {x}")
    ck(f"{v1:X}", "1", 10, "i128 1 {X}")
    ck(f"{v1:o}", "1", 10, "i128 1 {o}")
    ck(f"{v1:b}", "1", 10, "i128 1 {b}")
    ck(f"{v1:#x}", "0x1", 10, "i128 1 {#x}")
    ck(f"{v1:#o}", "0o1", 10, "i128 1 {#o}")
    ck(f"{v1:#b}", "0b1", 10, "i128 1 {#b}")
    ck(f"{v2:x}", "ff", 10, "i128 255 {x}")
    ck(f"{v2:X}", "FF", 10, "i128 255 {X}")
    ck(f"{v2:o}", "377", 10, "i128 255 {o}")
    ck(f"{v2:b}", "11111111", 10, "i128 255 {b}")
    ck(f"{v2:#x}", "0xff", 10, "i128 255 {#x}")
    ck(f"{v2:#o}", "0o377", 10, "i128 255 {#o}")
    ck(f"{v2:#b}", "0b11111111", 10, "i128 255 {#b}")
    ck(f"{v2:20x}", "                  ff", 10, "i128 255 {20x}")
    ck(f"{v2:<20x}", "ff                  ", 10, "i128 255 {<20x}")
    ck(f"{v2:*>20x}", "******************ff", 10, "i128 255 {*>20x}")
    ck(f"{v2:→<20X}", "FF→→→→→→→→→→→→→→→→→→", 10, "i128 255 {→<20X}")
    ck(f"{v2:020x}", "000000000000000000ff", 10, "i128 255 {020x}")
    ck(f"{v2:#020x}", "0x0000000000000000ff", 10, "i128 255 {#020x}")
    ck(f"{v2:#030o}", "0o0000000000000000000000000377", 10, "i128 255 {#030o}")
    ck(f"{v2:#040b}", "0b00000000000000000000000000000011111111", 10, "i128 255 {#040b}")
    ck(f"{v2:日>#40b}", "日日日日日日日日日日日日日日日日日日日日日日日日日日日日日日0b11111111", 10, "i128 255 {日>#40b}")
    ck(f"{v2:😀^#24x}", "😀😀😀😀😀😀😀😀😀😀0xff😀😀😀😀😀😀😀😀😀😀", 10, "i128 255 {😀^#24x}")
    ck(f"{v2:+x}", "+ff", 10, "i128 255 {+x}")
    ck(f"{v2:+#12x}", "       +0xff", 10, "i128 255 {+#12x}")
    ck(f"{v2:+#012b}", "+0b011111111", 10, "i128 255 {+#012b}")
    ck(f"{v2:_<+12o}", "+377________", 10, "i128 255 {_<+12o}")
    ck(f"{v3:x}", "10000000000000000", 10, "i128 big {x}")
    ck(f"{v3:X}", "10000000000000000", 10, "i128 big {X}")
    ck(f"{v3:o}", "2000000000000000000000", 10, "i128 big {o}")
    ck(f"{v3:b}", "10000000000000000000000000000000000000000000000000000000000000000", 10, "i128 big {b}")
    ck(f"{v3:#x}", "0x10000000000000000", 10, "i128 big {#x}")
    ck(f"{v3:#o}", "0o2000000000000000000000", 10, "i128 big {#o}")
    ck(f"{v3:#b}", "0b10000000000000000000000000000000000000000000000000000000000000000", 10, "i128 big {#b}")
    ck(f"{v4:x}", "7fffffffffffffffffffffffffffffff", 10, "i128 big {x}")
    ck(f"{v4:X}", "7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", 10, "i128 big {X}")
    ck(f"{v4:o}", "1777777777777777777777777777777777777777777", 10, "i128 big {o}")
    ck(f"{v4:b}", "1111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111", 10, "i128 big {b}")
    ck(f"{v4:#x}", "0x7fffffffffffffffffffffffffffffff", 10, "i128 big {#x}")
    ck(f"{v4:#o}", "0o1777777777777777777777777777777777777777777", 10, "i128 big {#o}")
    ck(f"{v4:#b}", "0b1111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111", 10, "i128 big {#b}")
    ck(f"{v4:20x}", "7fffffffffffffffffffffffffffffff", 10, "i128 big {20x}")
    ck(f"{v4:<20x}", "7fffffffffffffffffffffffffffffff", 10, "i128 big {<20x}")
    ck(f"{v4:*>20x}", "7fffffffffffffffffffffffffffffff", 10, "i128 big {*>20x}")
    ck(f"{v4:→<20X}", "7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", 10, "i128 big {→<20X}")
    ck(f"{v4:020x}", "7fffffffffffffffffffffffffffffff", 10, "i128 big {020x}")
    ck(f"{v4:#020x}", "0x7fffffffffffffffffffffffffffffff", 10, "i128 big {#020x}")
    ck(f"{v4:#030o}", "0o1777777777777777777777777777777777777777777", 10, "i128 big {#030o}")
    ck(f"{v4:#040b}", "0b1111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111", 10, "i128 big {#040b}")
    ck(f"{v4:日>#40b}", "0b1111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111", 10, "i128 big {日>#40b}")
    ck(f"{v4:😀^#24x}", "0x7fffffffffffffffffffffffffffffff", 10, "i128 big {😀^#24x}")
    ck(f"{v4:+x}", "+7fffffffffffffffffffffffffffffff", 10, "i128 big {+x}")
    ck(f"{v4:+#12x}", "+0x7fffffffffffffffffffffffffffffff", 10, "i128 big {+#12x}")
    ck(f"{v4:+#012b}", "+0b1111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111", 10, "i128 big {+#012b}")
    ck(f"{v4:_<+12o}", "+1777777777777777777777777777777777777777777", 10, "i128 big {_<+12o}")
}

fn main() -> i32 {
    bases_u128()
    bases_i128()
    if CODE == 0 {
        println("ok")
    }

    return CODE
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: ok
