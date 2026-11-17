/// builtin/base/text_int.k
///
/// Integer <-> decimal text on raw byte buffers.
///
/// Value to text writes the digits right-aligned in a caller buffer and
/// returns where they start. Text to value takes a pointer and a length and
/// reports failure through a `ParseError`; the returned value means something
/// only when `err.kind` is `ParseErrorKind::None`.
///
/// Nothing here allocates, calls libc or depends on byte order.

import base::intrinsics::*
import string::*

/// "00" "01" ... "99": the two ASCII digits of every value below 100.
priv static const NUMTEXT_DIGIT_PAIRS: [u8; 200] = [
    48, 48, 48, 49, 48, 50, 48, 51,
    48, 52, 48, 53, 48, 54, 48, 55,
    48, 56, 48, 57, 49, 48, 49, 49,
    49, 50, 49, 51, 49, 52, 49, 53,
    49, 54, 49, 55, 49, 56, 49, 57,
    50, 48, 50, 49, 50, 50, 50, 51,
    50, 52, 50, 53, 50, 54, 50, 55,
    50, 56, 50, 57, 51, 48, 51, 49,
    51, 50, 51, 51, 51, 52, 51, 53,
    51, 54, 51, 55, 51, 56, 51, 57,
    52, 48, 52, 49, 52, 50, 52, 51,
    52, 52, 52, 53, 52, 54, 52, 55,
    52, 56, 52, 57, 53, 48, 53, 49,
    53, 50, 53, 51, 53, 52, 53, 53,
    53, 54, 53, 55, 53, 56, 53, 57,
    54, 48, 54, 49, 54, 50, 54, 51,
    54, 52, 54, 53, 54, 54, 54, 55,
    54, 56, 54, 57, 55, 48, 55, 49,
    55, 50, 55, 51, 55, 52, 55, 53,
    55, 54, 55, 55, 55, 56, 55, 57,
    56, 48, 56, 49, 56, 50, 56, 51,
    56, 52, 56, 53, 56, 54, 56, 55,
    56, 56, 56, 57, 57, 48, 57, 49,
    57, 50, 57, 51, 57, 52, 57, 53,
    57, 54, 57, 55, 57, 56, 57, 57,
]

/// True when a 64-bit divide is one instruction: every 64-bit target, and
/// the ILP32 ABIs of 64-bit CPUs (x32, aarch64 ILP32) and wasm32, whose
/// registers are 64 bits wide whatever the pointer width is. Elsewhere a
/// `u64 / u64` is a runtime library call and formatting works in 32 bits.
/// `-DKAIRO_NUMTEXT_NARROW` forces the 32-bit path on any target.
// COMPILER-WORKAROUND(eval-if-decl-twice): one declaration, not one per
// branch of an `eval if`: an importer of an importer sees both branches'.
prot eval NUMTEXT_WIDE: bool = !defined!(KAIRO_NUMTEXT_NARROW) && (sizeof usize == 8 || defined!(__x86_64__) || defined!(__aarch64__) || defined!(__wasm__))

/// The longest text of each type, sign included.
prot eval U8_TEXT_MAX:  usize = 3
prot eval U16_TEXT_MAX: usize = 5
prot eval U32_TEXT_MAX: usize = 10
prot eval U64_TEXT_MAX: usize = 20
prot eval I8_TEXT_MAX:  usize = 4
prot eval I16_TEXT_MAX: usize = 6
prot eval I32_TEXT_MAX: usize = 11
prot eval I64_TEXT_MAX: usize = 20

/// The text occupies `buf[start .. start + len)`, and `start + len` is the
/// `cap` the writer was given.
prot struct TextRange {
    pub var start: usize
    pub var len:   usize
}

// --- value to text -----------------------------------------------------------

/// Writes the two digits of `v` (below 100) at `buf[at]` and `buf[at + 1]`.
inline fn put_pair(buf: unsafe *u8, at: usize, v: u32) {
    var i = (v as usize) * 2
    buf[at]     = NUMTEXT_DIGIT_PAIRS[i]
    buf[at + 1] = NUMTEXT_DIGIT_PAIRS[i + 1]
}

/// Writes `v` so that its last digit is `buf[end - 1]`; returns the index of
/// its first digit. At most 10 bytes.
inline fn put_u32(buf: unsafe *u8, end: usize, v: u32) -> usize {
    var p = end
    var x = v
    while x >= 100 {
        var q = x / 100
        p -= 2
        put_pair(buf, p, x - q * 100)
        x = q
    }

    if x >= 10 {
        p -= 2
        put_pair(buf, p, x)
    } else {
        p -= 1
        buf[p] = (48 + x) as u8
    }

    return p
}

/// Writes exactly nine digits of `v` (below 10^9), zero padded, ending at
/// `buf[end - 1]`; returns `end - 9`.
inline fn put_u32_pad9(buf: unsafe *u8, end: usize, v: u32) -> usize {
    var p = end
    var x = v
    for var i: i32 = 0; i < 4; ++i {
        var q = x / 100
        p -= 2
        put_pair(buf, p, x - q * 100)
        x = q
    }

    p -= 1
    buf[p] = (48 + x) as u8
    return p
}

/// Writes `v` so that its last digit is `buf[end - 1]`; returns the index of
/// its first digit. At most 20 bytes.
///
/// Where a 64-bit divide is a library call the value is cut into base-10^9
/// chunks with at most two of them, and every digit comes from 32-bit
/// arithmetic.
inline fn put_u64(buf: unsafe *u8, end: usize, v: u64) -> usize {
    eval if NUMTEXT_WIDE {
        var p = end
        var x = v
        while x >= 100 {
            var q = x / 100
            p -= 2
            put_pair(buf, p, (x - q * 100) as u32)
            x = q
        }

        if x >= 10 {
            p -= 2
            put_pair(buf, p, x as u32)
        } else {
            p -= 1
            buf[p] = (48 + x) as u8
        }

        return p
    } else {
        if v <= 0xFFFFFFFF {
            return put_u32(buf, end, v as u32)
        }

        // The remainders are below 2^32, so the low words alone give them.
        var hi = v / 1000000000
        var lo = (v as u32) - (hi as u32) * 1000000000u32
        var p  = put_u32_pad9(buf, end, lo)
        if hi < 1000000000 {
            return put_u32(buf, p, hi as u32)
        }

        var top = (hi / 1000000000) as u32
        var mid = (hi as u32) - top * 1000000000u32
        p = put_u32_pad9(buf, p, mid)
        return put_u32(buf, p, top)
    }
}

inline fn range_from(start: usize, cap: usize) -> TextRange = TextRange {
    start: start,
    len:   cap - start,
}

/// Writes the decimal text of `v` at the end of `buf[0 .. cap)`.
///
/// \pre `cap >= U32_TEXT_MAX` (10); `buf` is valid for writes of `cap` bytes.
prot inline fn u32_to_text(v: u32, buf: unsafe *u8, cap: usize) -> TextRange {
    return range_from(put_u32(buf, cap, v), cap)
}

/// \pre `cap >= U64_TEXT_MAX` (20).
prot inline fn u64_to_text(v: u64, buf: unsafe *u8, cap: usize) -> TextRange {
    return range_from(put_u64(buf, cap, v), cap)
}

/// The magnitude is taken in the unsigned type, so the minimum value needs
/// no special case.
///
/// \pre `cap >= I32_TEXT_MAX` (11).
prot inline fn i32_to_text(v: i32, buf: unsafe *u8, cap: usize) -> TextRange {
    var neg = v < 0
    var mag = if neg => 0u32 - (v as u32) else => v as u32
    var p   = put_u32(buf, cap, mag)
    if neg {
        p -= 1
        buf[p] = 45
    }

    return range_from(p, cap)
}

/// \pre `cap >= I64_TEXT_MAX` (20).
prot inline fn i64_to_text(v: i64, buf: unsafe *u8, cap: usize) -> TextRange {
    var neg = v < 0
    var mag = if neg => 0u64 - (v as u64) else => v as u64
    var p   = put_u64(buf, cap, mag)
    if neg {
        p -= 1
        buf[p] = 45
    }

    return range_from(p, cap)
}

/// \pre `cap >= U8_TEXT_MAX` (3).
prot inline fn u8_to_text(v: u8, buf: unsafe *u8, cap: usize) -> TextRange = u32_to_text(
    v,
    buf,
    cap,
)

/// \pre `cap >= U16_TEXT_MAX` (5).
prot inline fn u16_to_text(v: u16, buf: unsafe *u8, cap: usize) -> TextRange = u32_to_text(
    v,
    buf,
    cap,
)

/// \pre `cap >= I8_TEXT_MAX` (4).
prot inline fn i8_to_text(v: i8, buf: unsafe *u8, cap: usize) -> TextRange = i32_to_text(
    v,
    buf,
    cap,
)

/// \pre `cap >= I16_TEXT_MAX` (6).
prot inline fn i16_to_text(v: i16, buf: unsafe *u8, cap: usize) -> TextRange = i32_to_text(
    v,
    buf,
    cap,
)

/// \pre `cap >= U64_TEXT_MAX` (20) covers every target.
prot inline fn usize_to_text(v: usize, buf: unsafe *u8, cap: usize) -> TextRange {
    eval if sizeof usize == 8 {
        return u64_to_text(v as u64, buf, cap)
    } else {
        return u32_to_text(v as u32, buf, cap)
    }
}

/// \pre `cap >= I64_TEXT_MAX` (20) covers every target.
prot inline fn isize_to_text(v: isize, buf: unsafe *u8, cap: usize) -> TextRange {
    eval if sizeof usize == 8 {
        return i64_to_text(v as i64, buf, cap)
    } else {
        return i32_to_text(v as i32, buf, cap)
    }
}

// --- text to value -----------------------------------------------------------

/// Records the failure and returns the value every failed parse returns.
@cold_path @no_inline fn int_fail(@inout err: ParseError, at: usize, kind: ParseErrorKind) -> u64 {
    err.at   = if at > 0xFFFFFFFF => 0xFFFFFFFFu32 else => at as u32
    err.kind = kind
    return 0
}

/// Reports the digits `p[from ..)`, whose value exceeds `limit`: `Trailing`
/// at a byte after them when there is one, otherwise `Overflow` at the digit
/// that first takes the value above `limit`.
@cold_path @no_inline fn int_overflow(p:          unsafe *const u8,
                                      from:       usize,
                                      n:          usize,
                                      limit:      u64,
                                      @inout err: ParseError) -> u64 {
    var end = from
    while end < n && (p[end] - 48) <= 9 {
        end += 1
    }

    if end < n {
        return int_fail(&err, end, ParseErrorKind::Trailing)
    }

    var acc: u64 = 0
    var i        = from
    loop {
        var d: u64 = p[i] - 48
        // acc * 10 + d > limit, without overflowing.
        if acc > (limit - d) / 10 {
            break
        }

        acc = acc * 10 + d
        i += 1
    }

    return int_fail(&err, i, ParseErrorKind::Overflow)
}

/// Parses the digits `p[from .. n)` as a value in `[0, limit]`.
///
/// Up to 18 digits cannot overflow a `u64`, so they accumulate unchecked and
/// the range is checked once; digits beyond them (leading zeros included)
/// use checked arithmetic.
inline fn parse_digits(p:          unsafe *const u8,
                       from:       usize,
                       n:          usize,
                       limit:      u64,
                       @inout err: ParseError) -> u64 {
    if from == n {
        return int_fail(
            &err,
            from,
            if from == 0 => ParseErrorKind::Empty else => ParseErrorKind::InvalidChar,
        )
    }

    var acc: u64 = 0
    var i        = from
    var stop     = if n - from > 18 => from + 18 else => n
    while i < stop {
        var d = p[i] - 48
        if d > 9 {
            break
        }

        acc = acc * 10 + (d as u64)
        i += 1
    }

    if i == from {
        return int_fail(&err, from, ParseErrorKind::InvalidChar)
    }

    if i == stop {
        while i < n {
            var d = p[i] - 48
            if d > 9 {
                break
            }

            if __builtin_mul_overflow(acc, 10u64, &acc)
                || __builtin_add_overflow(acc, d as u64, &acc) {
                return int_overflow(p, from, n, limit, &err)
            }

            i += 1
        }
    }

    if acc > limit {
        return int_overflow(p, from, n, limit, &err)
    }

    if i < n {
        return int_fail(&err, i, ParseErrorKind::Trailing)
    }

    return acc
}

/// Parses `[+]digits` as a value in `[0, max]`.
///
/// \pre `p` is valid for reads of `n` bytes.
prot inline fn parse_unsigned(p:          unsafe *const u8,
                              n:          usize,
                              max:        u64,
                              @inout err: ParseError) -> u64 {
    err.at   = 0
    err.kind = ParseErrorKind::None
    var from: usize = 0
    if n != 0 && p[0] == 43 {
        if n == 1 {
            return int_fail(&err, 0, ParseErrorKind::InvalidChar)
        }

        from = 1
    }

    return parse_digits(p, from, n, max, &err)
}

/// Parses `[+-]digits` as a value in `[-max - 1, max]`.
///
/// \pre `p` is valid for reads of `n` bytes; `max` is `2^k - 1` for the
/// type's `k` value bits.
prot inline fn parse_signed(p:          unsafe *const u8,
                            n:          usize,
                            max:        u64,
                            @inout err: ParseError) -> i64 {
    err.at   = 0
    err.kind = ParseErrorKind::None
    var from: usize = 0
    var neg         = false
    if n != 0 && (p[0] == 43 || p[0] == 45) {
        if n == 1 {
            return int_fail(&err, 0, ParseErrorKind::InvalidChar) as i64
        }

        neg  = p[0] == 45
        from = 1
    }

    var mag = parse_digits(p, from, n, if neg => max + 1 else => max, &err)
    return (if neg => 0u64 - mag else => mag) as i64
}

prot inline fn parse_u8(p:          unsafe *const u8,
                        n:          usize,
                        @inout err: ParseError) -> u8 = parse_unsigned(
    p,
    n,
    0xFF,
    &err,
) as u8

prot inline fn parse_u16(p:          unsafe *const u8,
                         n:          usize,
                         @inout err: ParseError) -> u16 = parse_unsigned(
    p,
    n,
    0xFFFF,
    &err,
) as u16

prot inline fn parse_u32(p:          unsafe *const u8,
                         n:          usize,
                         @inout err: ParseError) -> u32 = parse_unsigned(
    p,
    n,
    0xFFFFFFFF,
    &err,
) as u32

prot inline fn parse_u64(p:          unsafe *const u8,
                         n:          usize,
                         @inout err: ParseError) -> u64 = parse_unsigned(
    p,
    n,
    0xFFFFFFFFFFFFFFFF,
    &err,
)

prot inline fn parse_i8(p: unsafe *const u8, n: usize, @inout err: ParseError) -> i8 = parse_signed(
    p,
    n,
    0x7F,
    &err,
) as i8

prot inline fn parse_i16(p:          unsafe *const u8,
                         n:          usize,
                         @inout err: ParseError) -> i16 = parse_signed(
    p,
    n,
    0x7FFF,
    &err,
) as i16

prot inline fn parse_i32(p:          unsafe *const u8,
                         n:          usize,
                         @inout err: ParseError) -> i32 = parse_signed(
    p,
    n,
    0x7FFFFFFF,
    &err,
) as i32

prot inline fn parse_i64(p:          unsafe *const u8,
                         n:          usize,
                         @inout err: ParseError) -> i64 = parse_signed(
    p,
    n,
    0x7FFFFFFFFFFFFFFF,
    &err,
)

prot inline fn parse_usize(p: unsafe *const u8, n: usize, @inout err: ParseError) -> usize {
    eval if sizeof usize == 8 {
        return parse_unsigned(p, n, 0xFFFFFFFFFFFFFFFF, &err) as usize
    } else {
        return parse_unsigned(p, n, 0xFFFFFFFF, &err) as usize
    }
}

prot inline fn parse_isize(p: unsafe *const u8, n: usize, @inout err: ParseError) -> isize {
    eval if sizeof usize == 8 {
        return parse_signed(p, n, 0x7FFFFFFFFFFFFFFF, &err) as isize
    } else {
        return parse_signed(p, n, 0x7FFFFFFF, &err) as isize
    }
}
