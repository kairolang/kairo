/// builtin/base/prim.k

import base::cmp::*
import base::hash::*
import base::intrinsics::*
import base::text_char::*
import base::text_float::*
import base::text_int::*
import builtin::Null
import string::*

/// u8..u64, i8..i64, usize, isize, f32, f64, bool, char.
/// No Hash for floats (NaN != NaN, -0.0 == 0.0). No Default for bool.
/// u128 and i128 have no text conversions here.

// One buffer size for every type the macros stamp: the longest text is an
// f64's (F64_TEXT_MAX); a 64-bit integer needs 20, a char 4. It is
// `string::BLOCK_`, the length `push_block_` copies.
priv eval TEXT_BUF: usize = 24

// The macros stamp one body per type, so each type carries its own cores as
// statics of an extend block, which is per Kairo type: usize and isize share
// their C++ spelling with a fixed-width type, so free overloads would
// collide. Integers write right-aligned and the others left-aligned; all come
// back as the TextRange of the bytes written. Every text but a non-ASCII
// char's is ASCII, so `push_str` need not count it.
// `word` is `v` for an unsigned type and `v as u64` for a signed one: the
// hash of a signed value is that of its sign-extended bits.
priv macro prim_int_core!(T, to_text, parse, word) {
    extend T {
        priv static inline fn hash_word(v: T) -> u64 = word
        priv static inline fn text_of(v: T, buf: unsafe *u8) -> TextRange = to_text(v, buf, TEXT_BUF)
        priv static inline fn ascii_text(v: T) -> bool = true
        priv static inline fn parse_into(p: unsafe *const u8, n: usize, @inout err: ParseError) -> T = parse(p, n, &err)
    }
}

prim_int_core!(u8, u8_to_text, parse_u8, v)
prim_int_core!(u16, u16_to_text, parse_u16, v)
prim_int_core!(u32, u32_to_text, parse_u32, v)
prim_int_core!(u64, u64_to_text, parse_u64, v)
prim_int_core!(i8, i8_to_text, parse_i8, v as u64)
prim_int_core!(i16, i16_to_text, parse_i16, v as u64)
prim_int_core!(i32, i32_to_text, parse_i32, v as u64)
prim_int_core!(i64, i64_to_text, parse_i64, v as u64)
prim_int_core!(usize, usize_to_text, parse_usize, v as u64)
prim_int_core!(isize, isize_to_text, parse_isize, v as u64)

extend f64 {
    priv static inline fn text_of(v: f64, buf: unsafe *u8) -> TextRange = TextRange { start: 0, len: f64_to_text(v, buf) }
    priv static inline fn ascii_text(v: f64) -> bool = true
    priv static inline fn parse_into(p: unsafe *const u8, n: usize, @inout err: ParseError) -> f64 = parse_f64(p, n, &err)
}

extend f32 {
    priv static inline fn text_of(v: f32, buf: unsafe *u8) -> TextRange = TextRange { start: 0, len: f32_to_text(v, buf) }
    priv static inline fn ascii_text(v: f32) -> bool = true
    priv static inline fn parse_into(p: unsafe *const u8, n: usize, @inout err: ParseError) -> f32 = parse_f32(p, n, &err)
}

extend char {
    priv static inline fn text_of(v: char, buf: unsafe *u8) -> TextRange = TextRange { start: 0, len: char_to_utf8(v, buf) }
    priv static inline fn hash_word(v: char) -> u64 = v
    priv static inline fn ascii_text(v: char) -> bool = (v as u32) < 0x80
    priv static inline fn parse_into(p: unsafe *const u8, n: usize, @inout err: ParseError) -> char = parse_char(p, n, &err)
}

extend bool {
    priv static inline fn text_of(v: bool, buf: unsafe *u8) -> TextRange {
        unsafe {
            if v {
                buf[0] = 116 // t
                buf[1] = 114 // r
                buf[2] = 117 // u
                buf[3] = 101 // e
                return TextRange { start: 0, len: 4 }
            }

            buf[0] = 102 // f
            buf[1] = 97  // a
            buf[2] = 108 // l
            buf[3] = 115 // s
            buf[4] = 101 // e
            return TextRange { start: 0, len: 5 }
        }
    }

    priv static inline fn hash_word(v: bool) -> u64 = if v => 1 else => 0
    priv static inline fn ascii_text(v: bool) -> bool = true
    priv static inline fn parse_into(p: unsafe *const u8, n: usize, @inout err: ParseError) -> bool = parse_bool(p, n, &err)
}

priv macro prim_default!(T, zero) {
    extend T impl Default {
        static inline fn make_default() -> T = zero
    }
}

priv macro prim_hash!(T) {
    extend T impl Hash {
        inline fn hash(const self, @inout h: Hasher) {
            h.write_u64(T::hash_word(self))
        }
    }
}

// `append_to` formats into a stack buffer and appends it with one
// `push_block_` (ASCII text) or one `push_str` of a borrowed view: no
// temporary string, no allocation beyond the destination's own growth. The
// buffer is two TEXT_BUF long and the text lies in its first half, so a
// read of TEXT_BUF bytes from the text's first byte stays inside it. `from_str` reports through `err` and turns a
// failure into null at the boundary; the cores never read at or past
// `s.size()`, so a view is a valid argument.
priv macro prim_text!(T) {
    extend T impl ToString {
        inline fn op as (const self) -> string {
            var buf: [u8; TEXT_BUF]
            unsafe {
                var unsafe *b = &buf[0] as unsafe *u8
                var        r  = T::text_of(self, b)
                return string((b + r.start) as *const u8, r.len)
            }
        }
    }

    extend T impl Append {
        inline fn append_to(const self, @inout out: string) {
            var buf: [u8; 2 * TEXT_BUF]
            unsafe {
                var unsafe *b = &buf[0] as unsafe *u8
                var        r  = T::text_of(self, b)
                if T::ascii_text(self) {
                    out.push_block_((b + r.start) as *const u8, r.len)
                } else {
                    out.push_str(string::view_of_((b + r.start) as *const u8, r.len))
                }
            }
        }
    }

    extend T impl FromStr {
        static inline fn from_str(const s: string, @inout err: ParseError) -> T? {
            var v = T::parse_into(unsafe (s.data() as unsafe *const u8), s.size(), &err)

            if err.kind != ParseErrorKind::None {
                return null
            }

            return v
        }
    }
}

prim_default!(u8, 0)
prim_default!(u16, 0)
prim_default!(u32, 0)
prim_default!(u64, 0)
prim_default!(i8, 0)
prim_default!(i16, 0)
prim_default!(i32, 0)
prim_default!(i64, 0)
prim_default!(usize, 0)
prim_default!(isize, 0)
prim_default!(f32, 0.0)
prim_default!(f64, 0.0)

// Written out: a char literal passed as a macro argument does not reach the
// emitted C++ intact.
extend char impl Default {
    static inline fn make_default() -> char = '\x00'
}

prim_hash!(u8)
prim_hash!(u16)
prim_hash!(u32)
prim_hash!(u64)
prim_hash!(i8)
prim_hash!(i16)
prim_hash!(i32)
prim_hash!(i64)
prim_hash!(usize)
prim_hash!(isize)
prim_hash!(bool)
prim_hash!(char)

// A 128-bit integer does not fit `hash_word`'s u64: both halves are fed.
priv macro prim_hash_wide!(T) {
    extend T impl Hash {
        inline fn hash(const self, @inout h: Hasher) {
            var v = self as u128
            h.write_u64(v as u64)
            h.write_u64((v >> 64) as u64)
        }
    }
}

prim_hash_wide!(u128)
prim_hash_wide!(i128)

prim_text!(u8)
prim_text!(u16)
prim_text!(u32)
prim_text!(u64)
prim_text!(i8)
prim_text!(i16)
prim_text!(i32)
prim_text!(i64)
prim_text!(usize)
prim_text!(isize)
prim_text!(f32)
prim_text!(f64)
prim_text!(bool)
prim_text!(char)
