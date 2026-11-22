/// builtin/base/text_char.k
///
/// `char` <-> UTF-8 and `bool` from text, on raw byte buffers.
///
/// Nothing here allocates, calls libc or depends on byte order.

import base::intrinsics::*
import string::*

/// The longest UTF-8 encoding of a scalar value.
prot eval CHAR_TEXT_MAX: usize = 4

/// Writes the UTF-8 encoding of `c` at `buf[0 ..)` and returns its length,
/// 1 to 4.
///
/// **Precondition:** `buf` is valid for writes of `CHAR_TEXT_MAX` (4) bytes; `c` is a
/// Unicode scalar value, which every `char` is.
prot fn char_to_utf8(c: char, buf: unsafe *u8) -> usize {
    var v: u32 = c
    if v < 0x80 {
        buf[0] = v as u8
        return 1
    }

    if v < 0x800 {
        buf[0] = (0xC0 | (v >> 6)) as u8
        buf[1] = (0x80 | (v & 0x3F)) as u8
        return 2
    }

    if v < 0x10000 {
        buf[0] = (0xE0 | (v >> 12)) as u8
        buf[1] = (0x80 | ((v >> 6) & 0x3F)) as u8
        buf[2] = (0x80 | (v & 0x3F)) as u8
        return 3
    }

    buf[0] = (0xF0 | (v >> 18)) as u8
    buf[1] = (0x80 | ((v >> 12) & 0x3F)) as u8
    buf[2] = (0x80 | ((v >> 6) & 0x3F)) as u8
    buf[3] = (0x80 | (v & 0x3F)) as u8
    return 4
}

/// Records the failure and returns the value every failed parse returns.
@cold_path @no_inline fn text_fail(@inout err: ParseError, at: usize, kind: ParseErrorKind) -> u32 {
    err.at   = if at > 0xFFFFFFFF => 0xFFFFFFFFu32 else => at as u32
    err.kind = kind
    return 0
}

/// Parses text that is exactly one UTF-8 encoded scalar value.
///
/// The first sequence must be well formed: shortest form, not a surrogate,
/// at most U+10FFFF, and complete. Anything else is `InvalidChar` at 0;
/// bytes after a well-formed first sequence are `Trailing` at its length.
///
/// **Precondition:** `p` is valid for reads of `n` bytes; `err` is clear
/// (kind `None`, at 0), and is written only on failure.
prot fn parse_char(p: unsafe *const u8, n: usize, @inout err: ParseError) -> char {
    if n == 0 {
        return text_fail(&err, 0, ParseErrorKind::Empty)
    }

    var b0:  u32   = p[0]
    var len: usize = 1
    var v          = b0
    var min: u32   = 0    // the smallest value this length may encode
    if b0 >= 0x80 {
        if b0 >= 0xC2 && b0 <= 0xDF {
            len = 2
            v   = b0 & 0x1F
            min = 0x80
        } else if b0 >= 0xE0 && b0 <= 0xEF {
            len = 3
            v   = b0 & 0x0F
            min = 0x800
        } else if b0 >= 0xF0 && b0 <= 0xF4 {
            len = 4
            v   = b0 & 0x07
            min = 0x10000
        } else {
            return text_fail(&err, 0, ParseErrorKind::InvalidChar)
        }

        if n < len {
            return text_fail(&err, 0, ParseErrorKind::InvalidChar)
        }

        for var i: usize = 1; i < len; ++i {
            var b: u32 = p[i]
            if (b & 0xC0) != 0x80 {
                return text_fail(&err, 0, ParseErrorKind::InvalidChar)
            }

            v = (v << 6) | (b & 0x3F)
        }

        if v < min || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) {
            return text_fail(&err, 0, ParseErrorKind::InvalidChar)
        }
    }

    if n > len {
        return text_fail(&err, len, ParseErrorKind::Trailing)
    }

    return v
}

/// Parses `true` or `false`, exactly.
///
/// Text that does not start with one of the two words is `InvalidChar` at
/// 0; bytes after the word are `Trailing` at its length.
///
/// **Precondition:** `p` is valid for reads of `n` bytes; `err` is clear
/// (kind `None`, at 0), and is written only on failure.
prot fn parse_bool(p: unsafe *const u8, n: usize, @inout err: ParseError) -> bool {
    if n == 0 {
        text_fail(&err, 0, ParseErrorKind::Empty)
        return false
    }

    if n >= 4 && p[0] == 116 && p[1] == 114 && p[2] == 117 && p[3] == 101 {
        if n > 4 {
            text_fail(&err, 4, ParseErrorKind::Trailing)
            return false
        }

        return true
    }

    if n >= 5 && p[0] == 102 && p[1] == 97 && p[2] == 108 && p[3] == 115 && p[4] == 101 {
        if n > 5 {
            text_fail(&err, 5, ParseErrorKind::Trailing)
        }

        return false
    }

    text_fail(&err, 0, ParseErrorKind::InvalidChar)
    return false
}
