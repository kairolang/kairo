// i8, i16, i32 and i64 (non-negative values) in base 16, 8 and 2 with `#`, `+`, width, fill, alignment and zero padding.
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

fn bases_i8() {
    var v0: i8 = 0
    var v1: i8 = 1
    var v2: i8 = 10
    var v3: i8 = 42
    var v4: i8 = i8::MAX
    ck(f"{v0:x}", "0", 5, "i8 0 {x}")
    ck(f"{v0:X}", "0", 5, "i8 0 {X}")
    ck(f"{v0:o}", "0", 5, "i8 0 {o}")
    ck(f"{v0:b}", "0", 5, "i8 0 {b}")
    ck(f"{v0:#x}", "0x0", 5, "i8 0 {#x}")
    ck(f"{v0:#o}", "0o0", 5, "i8 0 {#o}")
    ck(f"{v0:#b}", "0b0", 5, "i8 0 {#b}")
    ck(f"{v1:x}", "1", 5, "i8 1 {x}")
    ck(f"{v1:X}", "1", 5, "i8 1 {X}")
    ck(f"{v1:o}", "1", 5, "i8 1 {o}")
    ck(f"{v1:b}", "1", 5, "i8 1 {b}")
    ck(f"{v1:#x}", "0x1", 5, "i8 1 {#x}")
    ck(f"{v1:#o}", "0o1", 5, "i8 1 {#o}")
    ck(f"{v1:#b}", "0b1", 5, "i8 1 {#b}")
    ck(f"{v2:x}", "a", 5, "i8 10 {x}")
    ck(f"{v2:X}", "A", 5, "i8 10 {X}")
    ck(f"{v2:o}", "12", 5, "i8 10 {o}")
    ck(f"{v2:b}", "1010", 5, "i8 10 {b}")
    ck(f"{v2:#x}", "0xa", 5, "i8 10 {#x}")
    ck(f"{v2:#o}", "0o12", 5, "i8 10 {#o}")
    ck(f"{v2:#b}", "0b1010", 5, "i8 10 {#b}")
    ck(f"{v3:x}", "2a", 5, "i8 42 {x}")
    ck(f"{v3:X}", "2A", 5, "i8 42 {X}")
    ck(f"{v3:o}", "52", 5, "i8 42 {o}")
    ck(f"{v3:b}", "101010", 5, "i8 42 {b}")
    ck(f"{v3:#x}", "0x2a", 5, "i8 42 {#x}")
    ck(f"{v3:#o}", "0o52", 5, "i8 42 {#o}")
    ck(f"{v3:#b}", "0b101010", 5, "i8 42 {#b}")
    ck(f"{v4:x}", "7f", 5, "i8 127 {x}")
    ck(f"{v4:X}", "7F", 5, "i8 127 {X}")
    ck(f"{v4:o}", "177", 5, "i8 127 {o}")
    ck(f"{v4:b}", "1111111", 5, "i8 127 {b}")
    ck(f"{v4:#x}", "0x7f", 5, "i8 127 {#x}")
    ck(f"{v4:#o}", "0o177", 5, "i8 127 {#o}")
    ck(f"{v4:#b}", "0b1111111", 5, "i8 127 {#b}")
    ck(f"{v4:20x}", "                  7f", 5, "i8 127 {20x}")
    ck(f"{v4:<20x}", "7f                  ", 5, "i8 127 {<20x}")
    ck(f"{v4:*>20x}", "******************7f", 5, "i8 127 {*>20x}")
    ck(f"{v4:→<20X}", "7F→→→→→→→→→→→→→→→→→→", 5, "i8 127 {→<20X}")
    ck(f"{v4:020x}", "0000000000000000007f", 5, "i8 127 {020x}")
    ck(f"{v4:#020x}", "0x00000000000000007f", 5, "i8 127 {#020x}")
    ck(f"{v4:#030o}", "0o0000000000000000000000000177", 5, "i8 127 {#030o}")
    ck(f"{v4:#040b}", "0b00000000000000000000000000000001111111", 5, "i8 127 {#040b}")
    ck(f"{v4:日>#40b}", "日日日日日日日日日日日日日日日日日日日日日日日日日日日日日日日0b1111111", 5, "i8 127 {日>#40b}")
    ck(f"{v4:😀^#24x}", "😀😀😀😀😀😀😀😀😀😀0x7f😀😀😀😀😀😀😀😀😀😀", 5, "i8 127 {😀^#24x}")
    ck(f"{v4:+x}", "+7f", 5, "i8 127 {+x}")
    ck(f"{v4:+#12x}", "       +0x7f", 5, "i8 127 {+#12x}")
    ck(f"{v4:+#012b}", "+0b001111111", 5, "i8 127 {+#012b}")
    ck(f"{v4:_<+12o}", "+177________", 5, "i8 127 {_<+12o}")
}

fn bases_i16() {
    var v0: i16 = 0
    var v1: i16 = 1
    var v2: i16 = 10
    var v3: i16 = 42
    var v4: i16 = i16::MAX
    ck(f"{v0:x}", "0", 6, "i16 0 {x}")
    ck(f"{v0:X}", "0", 6, "i16 0 {X}")
    ck(f"{v0:o}", "0", 6, "i16 0 {o}")
    ck(f"{v0:b}", "0", 6, "i16 0 {b}")
    ck(f"{v0:#x}", "0x0", 6, "i16 0 {#x}")
    ck(f"{v0:#o}", "0o0", 6, "i16 0 {#o}")
    ck(f"{v0:#b}", "0b0", 6, "i16 0 {#b}")
    ck(f"{v1:x}", "1", 6, "i16 1 {x}")
    ck(f"{v1:X}", "1", 6, "i16 1 {X}")
    ck(f"{v1:o}", "1", 6, "i16 1 {o}")
    ck(f"{v1:b}", "1", 6, "i16 1 {b}")
    ck(f"{v1:#x}", "0x1", 6, "i16 1 {#x}")
    ck(f"{v1:#o}", "0o1", 6, "i16 1 {#o}")
    ck(f"{v1:#b}", "0b1", 6, "i16 1 {#b}")
    ck(f"{v2:x}", "a", 6, "i16 10 {x}")
    ck(f"{v2:X}", "A", 6, "i16 10 {X}")
    ck(f"{v2:o}", "12", 6, "i16 10 {o}")
    ck(f"{v2:b}", "1010", 6, "i16 10 {b}")
    ck(f"{v2:#x}", "0xa", 6, "i16 10 {#x}")
    ck(f"{v2:#o}", "0o12", 6, "i16 10 {#o}")
    ck(f"{v2:#b}", "0b1010", 6, "i16 10 {#b}")
    ck(f"{v3:x}", "2a", 6, "i16 42 {x}")
    ck(f"{v3:X}", "2A", 6, "i16 42 {X}")
    ck(f"{v3:o}", "52", 6, "i16 42 {o}")
    ck(f"{v3:b}", "101010", 6, "i16 42 {b}")
    ck(f"{v3:#x}", "0x2a", 6, "i16 42 {#x}")
    ck(f"{v3:#o}", "0o52", 6, "i16 42 {#o}")
    ck(f"{v3:#b}", "0b101010", 6, "i16 42 {#b}")
    ck(f"{v4:x}", "7fff", 6, "i16 32767 {x}")
    ck(f"{v4:X}", "7FFF", 6, "i16 32767 {X}")
    ck(f"{v4:o}", "77777", 6, "i16 32767 {o}")
    ck(f"{v4:b}", "111111111111111", 6, "i16 32767 {b}")
    ck(f"{v4:#x}", "0x7fff", 6, "i16 32767 {#x}")
    ck(f"{v4:#o}", "0o77777", 6, "i16 32767 {#o}")
    ck(f"{v4:#b}", "0b111111111111111", 6, "i16 32767 {#b}")
    ck(f"{v4:20x}", "                7fff", 6, "i16 32767 {20x}")
    ck(f"{v4:<20x}", "7fff                ", 6, "i16 32767 {<20x}")
    ck(f"{v4:*>20x}", "****************7fff", 6, "i16 32767 {*>20x}")
    ck(f"{v4:→<20X}", "7FFF→→→→→→→→→→→→→→→→", 6, "i16 32767 {→<20X}")
    ck(f"{v4:020x}", "00000000000000007fff", 6, "i16 32767 {020x}")
    ck(f"{v4:#020x}", "0x000000000000007fff", 6, "i16 32767 {#020x}")
    ck(f"{v4:#030o}", "0o0000000000000000000000077777", 6, "i16 32767 {#030o}")
    ck(f"{v4:#040b}", "0b00000000000000000000000111111111111111", 6, "i16 32767 {#040b}")
    ck(f"{v4:日>#40b}", "日日日日日日日日日日日日日日日日日日日日日日日0b111111111111111", 6, "i16 32767 {日>#40b}")
    ck(f"{v4:😀^#24x}", "😀😀😀😀😀😀😀😀😀0x7fff😀😀😀😀😀😀😀😀😀", 6, "i16 32767 {😀^#24x}")
    ck(f"{v4:+x}", "+7fff", 6, "i16 32767 {+x}")
    ck(f"{v4:+#12x}", "     +0x7fff", 6, "i16 32767 {+#12x}")
    ck(f"{v4:+#012b}", "+0b111111111111111", 6, "i16 32767 {+#012b}")
    ck(f"{v4:_<+12o}", "+77777______", 6, "i16 32767 {_<+12o}")
}

fn bases_i32() {
    var v0: i32 = 0
    var v1: i32 = 1
    var v2: i32 = 10
    var v3: i32 = 42
    var v4: i32 = 57005
    var v5: i32 = i32::MAX
    ck(f"{v0:x}", "0", 7, "i32 0 {x}")
    ck(f"{v0:X}", "0", 7, "i32 0 {X}")
    ck(f"{v0:o}", "0", 7, "i32 0 {o}")
    ck(f"{v0:b}", "0", 7, "i32 0 {b}")
    ck(f"{v0:#x}", "0x0", 7, "i32 0 {#x}")
    ck(f"{v0:#o}", "0o0", 7, "i32 0 {#o}")
    ck(f"{v0:#b}", "0b0", 7, "i32 0 {#b}")
    ck(f"{v1:x}", "1", 7, "i32 1 {x}")
    ck(f"{v1:X}", "1", 7, "i32 1 {X}")
    ck(f"{v1:o}", "1", 7, "i32 1 {o}")
    ck(f"{v1:b}", "1", 7, "i32 1 {b}")
    ck(f"{v1:#x}", "0x1", 7, "i32 1 {#x}")
    ck(f"{v1:#o}", "0o1", 7, "i32 1 {#o}")
    ck(f"{v1:#b}", "0b1", 7, "i32 1 {#b}")
    ck(f"{v2:x}", "a", 7, "i32 10 {x}")
    ck(f"{v2:X}", "A", 7, "i32 10 {X}")
    ck(f"{v2:o}", "12", 7, "i32 10 {o}")
    ck(f"{v2:b}", "1010", 7, "i32 10 {b}")
    ck(f"{v2:#x}", "0xa", 7, "i32 10 {#x}")
    ck(f"{v2:#o}", "0o12", 7, "i32 10 {#o}")
    ck(f"{v2:#b}", "0b1010", 7, "i32 10 {#b}")
    ck(f"{v3:x}", "2a", 7, "i32 42 {x}")
    ck(f"{v3:X}", "2A", 7, "i32 42 {X}")
    ck(f"{v3:o}", "52", 7, "i32 42 {o}")
    ck(f"{v3:b}", "101010", 7, "i32 42 {b}")
    ck(f"{v3:#x}", "0x2a", 7, "i32 42 {#x}")
    ck(f"{v3:#o}", "0o52", 7, "i32 42 {#o}")
    ck(f"{v3:#b}", "0b101010", 7, "i32 42 {#b}")
    ck(f"{v4:x}", "dead", 7, "i32 57005 {x}")
    ck(f"{v4:X}", "DEAD", 7, "i32 57005 {X}")
    ck(f"{v4:o}", "157255", 7, "i32 57005 {o}")
    ck(f"{v4:b}", "1101111010101101", 7, "i32 57005 {b}")
    ck(f"{v4:#x}", "0xdead", 7, "i32 57005 {#x}")
    ck(f"{v4:#o}", "0o157255", 7, "i32 57005 {#o}")
    ck(f"{v4:#b}", "0b1101111010101101", 7, "i32 57005 {#b}")
    ck(f"{v4:20x}", "                dead", 7, "i32 57005 {20x}")
    ck(f"{v4:<20x}", "dead                ", 7, "i32 57005 {<20x}")
    ck(f"{v4:*>20x}", "****************dead", 7, "i32 57005 {*>20x}")
    ck(f"{v4:→<20X}", "DEAD→→→→→→→→→→→→→→→→", 7, "i32 57005 {→<20X}")
    ck(f"{v4:020x}", "0000000000000000dead", 7, "i32 57005 {020x}")
    ck(f"{v4:#020x}", "0x00000000000000dead", 7, "i32 57005 {#020x}")
    ck(f"{v4:#030o}", "0o0000000000000000000000157255", 7, "i32 57005 {#030o}")
    ck(f"{v4:#040b}", "0b00000000000000000000001101111010101101", 7, "i32 57005 {#040b}")
    ck(f"{v4:日>#40b}", "日日日日日日日日日日日日日日日日日日日日日日0b1101111010101101", 7, "i32 57005 {日>#40b}")
    ck(f"{v4:😀^#24x}", "😀😀😀😀😀😀😀😀😀0xdead😀😀😀😀😀😀😀😀😀", 7, "i32 57005 {😀^#24x}")
    ck(f"{v4:+x}", "+dead", 7, "i32 57005 {+x}")
    ck(f"{v4:+#12x}", "     +0xdead", 7, "i32 57005 {+#12x}")
    ck(f"{v4:+#012b}", "+0b1101111010101101", 7, "i32 57005 {+#012b}")
    ck(f"{v4:_<+12o}", "+157255_____", 7, "i32 57005 {_<+12o}")
    ck(f"{v5:x}", "7fffffff", 7, "i32 big {x}")
    ck(f"{v5:X}", "7FFFFFFF", 7, "i32 big {X}")
    ck(f"{v5:o}", "17777777777", 7, "i32 big {o}")
    ck(f"{v5:b}", "1111111111111111111111111111111", 7, "i32 big {b}")
    ck(f"{v5:#x}", "0x7fffffff", 7, "i32 big {#x}")
    ck(f"{v5:#o}", "0o17777777777", 7, "i32 big {#o}")
    ck(f"{v5:#b}", "0b1111111111111111111111111111111", 7, "i32 big {#b}")
    ck(f"{v5:20x}", "            7fffffff", 7, "i32 big {20x}")
    ck(f"{v5:<20x}", "7fffffff            ", 7, "i32 big {<20x}")
    ck(f"{v5:*>20x}", "************7fffffff", 7, "i32 big {*>20x}")
    ck(f"{v5:→<20X}", "7FFFFFFF→→→→→→→→→→→→", 7, "i32 big {→<20X}")
    ck(f"{v5:020x}", "0000000000007fffffff", 7, "i32 big {020x}")
    ck(f"{v5:#020x}", "0x00000000007fffffff", 7, "i32 big {#020x}")
    ck(f"{v5:#030o}", "0o0000000000000000017777777777", 7, "i32 big {#030o}")
    ck(f"{v5:#040b}", "0b00000001111111111111111111111111111111", 7, "i32 big {#040b}")
    ck(f"{v5:日>#40b}", "日日日日日日日0b1111111111111111111111111111111", 7, "i32 big {日>#40b}")
    ck(f"{v5:😀^#24x}", "😀😀😀😀😀😀😀0x7fffffff😀😀😀😀😀😀😀", 7, "i32 big {😀^#24x}")
    ck(f"{v5:+x}", "+7fffffff", 7, "i32 big {+x}")
    ck(f"{v5:+#12x}", " +0x7fffffff", 7, "i32 big {+#12x}")
    ck(f"{v5:+#012b}", "+0b1111111111111111111111111111111", 7, "i32 big {+#012b}")
    ck(f"{v5:_<+12o}", "+17777777777", 7, "i32 big {_<+12o}")
}

fn bases_i64() {
    var v0: i64 = 0
    var v1: i64 = 1
    var v2: i64 = 10
    var v3: i64 = 42
    var v4: i64 = 57005
    var v5: i64 = i64::MAX
    ck(f"{v0:x}", "0", 8, "i64 0 {x}")
    ck(f"{v0:X}", "0", 8, "i64 0 {X}")
    ck(f"{v0:o}", "0", 8, "i64 0 {o}")
    ck(f"{v0:b}", "0", 8, "i64 0 {b}")
    ck(f"{v0:#x}", "0x0", 8, "i64 0 {#x}")
    ck(f"{v0:#o}", "0o0", 8, "i64 0 {#o}")
    ck(f"{v0:#b}", "0b0", 8, "i64 0 {#b}")
    ck(f"{v1:x}", "1", 8, "i64 1 {x}")
    ck(f"{v1:X}", "1", 8, "i64 1 {X}")
    ck(f"{v1:o}", "1", 8, "i64 1 {o}")
    ck(f"{v1:b}", "1", 8, "i64 1 {b}")
    ck(f"{v1:#x}", "0x1", 8, "i64 1 {#x}")
    ck(f"{v1:#o}", "0o1", 8, "i64 1 {#o}")
    ck(f"{v1:#b}", "0b1", 8, "i64 1 {#b}")
    ck(f"{v2:x}", "a", 8, "i64 10 {x}")
    ck(f"{v2:X}", "A", 8, "i64 10 {X}")
    ck(f"{v2:o}", "12", 8, "i64 10 {o}")
    ck(f"{v2:b}", "1010", 8, "i64 10 {b}")
    ck(f"{v2:#x}", "0xa", 8, "i64 10 {#x}")
    ck(f"{v2:#o}", "0o12", 8, "i64 10 {#o}")
    ck(f"{v2:#b}", "0b1010", 8, "i64 10 {#b}")
    ck(f"{v3:x}", "2a", 8, "i64 42 {x}")
    ck(f"{v3:X}", "2A", 8, "i64 42 {X}")
    ck(f"{v3:o}", "52", 8, "i64 42 {o}")
    ck(f"{v3:b}", "101010", 8, "i64 42 {b}")
    ck(f"{v3:#x}", "0x2a", 8, "i64 42 {#x}")
    ck(f"{v3:#o}", "0o52", 8, "i64 42 {#o}")
    ck(f"{v3:#b}", "0b101010", 8, "i64 42 {#b}")
    ck(f"{v4:x}", "dead", 8, "i64 57005 {x}")
    ck(f"{v4:X}", "DEAD", 8, "i64 57005 {X}")
    ck(f"{v4:o}", "157255", 8, "i64 57005 {o}")
    ck(f"{v4:b}", "1101111010101101", 8, "i64 57005 {b}")
    ck(f"{v4:#x}", "0xdead", 8, "i64 57005 {#x}")
    ck(f"{v4:#o}", "0o157255", 8, "i64 57005 {#o}")
    ck(f"{v4:#b}", "0b1101111010101101", 8, "i64 57005 {#b}")
    ck(f"{v4:20x}", "                dead", 8, "i64 57005 {20x}")
    ck(f"{v4:<20x}", "dead                ", 8, "i64 57005 {<20x}")
    ck(f"{v4:*>20x}", "****************dead", 8, "i64 57005 {*>20x}")
    ck(f"{v4:→<20X}", "DEAD→→→→→→→→→→→→→→→→", 8, "i64 57005 {→<20X}")
    ck(f"{v4:020x}", "0000000000000000dead", 8, "i64 57005 {020x}")
    ck(f"{v4:#020x}", "0x00000000000000dead", 8, "i64 57005 {#020x}")
    ck(f"{v4:#030o}", "0o0000000000000000000000157255", 8, "i64 57005 {#030o}")
    ck(f"{v4:#040b}", "0b00000000000000000000001101111010101101", 8, "i64 57005 {#040b}")
    ck(f"{v4:日>#40b}", "日日日日日日日日日日日日日日日日日日日日日日0b1101111010101101", 8, "i64 57005 {日>#40b}")
    ck(f"{v4:😀^#24x}", "😀😀😀😀😀😀😀😀😀0xdead😀😀😀😀😀😀😀😀😀", 8, "i64 57005 {😀^#24x}")
    ck(f"{v4:+x}", "+dead", 8, "i64 57005 {+x}")
    ck(f"{v4:+#12x}", "     +0xdead", 8, "i64 57005 {+#12x}")
    ck(f"{v4:+#012b}", "+0b1101111010101101", 8, "i64 57005 {+#012b}")
    ck(f"{v4:_<+12o}", "+157255_____", 8, "i64 57005 {_<+12o}")
    ck(f"{v5:x}", "7fffffffffffffff", 8, "i64 big {x}")
    ck(f"{v5:X}", "7FFFFFFFFFFFFFFF", 8, "i64 big {X}")
    ck(f"{v5:o}", "777777777777777777777", 8, "i64 big {o}")
    ck(f"{v5:b}", "111111111111111111111111111111111111111111111111111111111111111", 8, "i64 big {b}")
    ck(f"{v5:#x}", "0x7fffffffffffffff", 8, "i64 big {#x}")
    ck(f"{v5:#o}", "0o777777777777777777777", 8, "i64 big {#o}")
    ck(f"{v5:#b}", "0b111111111111111111111111111111111111111111111111111111111111111", 8, "i64 big {#b}")
    ck(f"{v5:20x}", "    7fffffffffffffff", 8, "i64 big {20x}")
    ck(f"{v5:<20x}", "7fffffffffffffff    ", 8, "i64 big {<20x}")
    ck(f"{v5:*>20x}", "****7fffffffffffffff", 8, "i64 big {*>20x}")
    ck(f"{v5:→<20X}", "7FFFFFFFFFFFFFFF→→→→", 8, "i64 big {→<20X}")
    ck(f"{v5:020x}", "00007fffffffffffffff", 8, "i64 big {020x}")
    ck(f"{v5:#020x}", "0x007fffffffffffffff", 8, "i64 big {#020x}")
    ck(f"{v5:#030o}", "0o0000000777777777777777777777", 8, "i64 big {#030o}")
    ck(f"{v5:#040b}", "0b111111111111111111111111111111111111111111111111111111111111111", 8, "i64 big {#040b}")
    ck(f"{v5:日>#40b}", "0b111111111111111111111111111111111111111111111111111111111111111", 8, "i64 big {日>#40b}")
    ck(f"{v5:😀^#24x}", "😀😀😀0x7fffffffffffffff😀😀😀", 8, "i64 big {😀^#24x}")
    ck(f"{v5:+x}", "+7fffffffffffffff", 8, "i64 big {+x}")
    ck(f"{v5:+#12x}", "+0x7fffffffffffffff", 8, "i64 big {+#12x}")
    ck(f"{v5:+#012b}", "+0b111111111111111111111111111111111111111111111111111111111111111", 8, "i64 big {+#012b}")
    ck(f"{v5:_<+12o}", "+777777777777777777777", 8, "i64 big {_<+12o}")
}

fn main() -> i32 {
    bases_i8()
    bases_i16()
    bases_i32()
    bases_i64()
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
