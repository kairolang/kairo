/// builtin/string.k
///
/// What the compiler calls by name, and so must keep its name and shape:
///   string()                          the empty string
///   string(lit, len, cp_len)          a string literal; the only 3-parameter constructor
///   op finally, the @move constructor
///   data(), size(), codepoints(), capacity()
///   op +=, push_str                   f-strings and `+`
///
/// What the rest of the builtin library may call (`prot`: this library only):
///   string::view_of_(p, n)            a view of n bytes of valid UTF-8, ASCII bit clear
///   string::ascii_view_(p, n)         a view of n ASCII bytes; `out.push_str(string::ascii_view_(p, n))`
///                                     appends them with no temporary, no count and no allocation
///                                     when `out` has room
///   s.push_ascii_(p, n)               the same append, spelled as one call
///   s.push_block_(p, n)               the same append of at most string::BLOCK_ bytes
///                                     from a buffer readable for that many
///   string::adopt_(bytes, cap, len, cps)
///                                     takes over a block laid out as a heap string's
///                                     (see `string::HEAP_HEADER_`)
///   string::encode_(c, out)           UTF-8 form of a char, 1 to 4 bytes
///   s.decode_at_(b), s.decode_before_(b)
///                                     the char that starts at, or ends at, byte b

import alloc_raw::{
    alloc_raw,
    free_raw,
    oom,
    resize_raw,
}
import base::c_char::*
import base::cmp::*
import base::copy::*
import base::hash::*
import base::intrinsics::*
import base::iter::*
import base::range::*
import builtin::Null
import containers::slice::*

priv eval STATE_MASK: usize = 3
priv eval ST_VIEW:    usize = 0 // borrowed, not NUL-terminated
priv eval ST_LIT:     usize = 1 // rodata, NUL-terminated
priv eval ST_HEAP:    usize = 3 // owned, NUL-terminated
priv eval NUL_BIT:    usize = 1 // set in literal and heap: p[len] == 0
priv eval OWN_BIT:    usize = 2 // set in heap only: the storage is owned and writable
priv eval ASCII_BIT:  usize = 4 // set: every byte is ASCII, so codepoints == bytes
priv eval LEN_SHIFT:  usize = 3
priv eval MAX_LEN:    usize = usize::MAX >> LEN_SHIFT

/// A word, the unit of every header and of every word-at-a-time loop.
priv eval W: usize = sizeof usize
// COMPILER-WORKAROUND(pure-builtin-ctz): a @pure function may not call
// __builtin_ctz, so the shift for a word count is a constant.
priv eval W_LOG2: usize = (W / 4) + 1 // 2 for a 4-byte word, 3 for an 8-byte one
/// Bytes in front of a heap string's first byte: `[cap: usize][conts: usize]`.
priv eval HDR: usize = 2 * W
/// The least `meta` of a string a word long: `meta >= WORD_META` is
/// `size() >= W`, whatever the state and ASCII bits are.
priv eval WORD_META: usize = W << LEN_SHIFT
/// The smallest capacity a string is promoted or grown to.
priv eval MIN_CAP: usize = 15

/// 0x01 in every byte, 0x80 in every byte, 0x7f in every byte.
priv eval BYTE_ONES:  usize = usize::MAX / 255
priv eval BYTE_HIGHS: usize = BYTE_ONES * 0x80
priv eval BYTE_LOW7:  usize = BYTE_ONES * 0x7f
/// 0x0001 in every 16-bit lane, and 0x00ff in every 16-bit lane.
priv eval PAIR_ONES: usize = usize::MAX / 0xffff
priv eval PAIR_LOWS: usize = PAIR_ONES * 0xff

/// `validate_`'s first result when the whole range is well-formed.
priv eval UTF8_OK: usize = usize::MAX

/// The empty string's bytes, a literal object `[cp_len = 0][NUL]`.
priv static EMPTY: [usize; 2] = [0, 0]

// --- words -------------------------------------------------------------------
//
// A word loop takes bytes until its cursor is W-aligned, then whole aligned
// words, then the tail bytes: no load is misaligned and none leaves the
// range it was given.

// COMPILER-WORKAROUND(pure-builtin-copy): a @pure function may not call
// __builtin_copy, so the aligned word is read through a typed pointer.
/// The word at `p`, in the target's byte order.
///
/// \safety `p` must be W-aligned and valid for reads of W bytes.
@pure priv inline fn load_word_(p: unsafe *const u8) -> usize {
    unsafe {
        return *(p as unsafe *const usize)
    }
}

/// Copies the word at `src` to `dst`, any alignment, and returns it.
///
/// \safety Both must be valid for W bytes; the ranges may overlap fully or not at all.
priv inline fn copy_word_(dst: unsafe *u8, src: unsafe *const u8) -> usize {
    var w: usize = 0
    unsafe {
        __builtin_copy(&w as unsafe *u8, src, W)
        __builtin_copy(dst, &w as unsafe *const u8, W)
    }

    return w
}

/// Copies the 4 bytes at `src` to `dst`, any alignment, and returns them.
///
/// \safety Both must be valid for 4 bytes; the ranges may overlap fully or not at all.
priv inline fn copy_u32_(dst: unsafe *u8, src: unsafe *const u8) -> usize {
    var v: u32 = 0
    unsafe {
        __builtin_copy(&v as unsafe *u8, src, 4)
        __builtin_copy(dst, &v as unsafe *const u8, 4)
    }

    return v as usize
}

/// Copies the 2 bytes at `src` to `dst`, any alignment, and returns them.
///
/// \safety Both must be valid for 2 bytes; the ranges may overlap fully or not at all.
priv inline fn copy_u16_(dst: unsafe *u8, src: unsafe *const u8) -> usize {
    var v: u16 = 0
    unsafe {
        __builtin_copy(&v as unsafe *u8, src, 2)
        __builtin_copy(dst, &v as unsafe *const u8, 2)
    }

    return v as usize
}

/// Copies the `n <= 8 * W` bytes at `src` to `dst` with no loop over bytes
/// and no call, and returns every byte ORed together (in some byte of the
/// result): words from the front and words from the back, which overlap in
/// the middle.
///
/// \safety Both must be valid for `n` bytes and must not overlap.
priv inline fn copy_short_(dst: unsafe *u8, src: unsafe *const u8, n: usize) -> usize {
    var acc: usize = 0
    unsafe {
        if n < W {
            // Under a word: two halves that overlap, then two byte pairs,
            // then the single byte.
            eval if sizeof usize > 4 {
                if n >= 4 {
                    return copy_u32_(dst, src) | copy_u32_(dst + (n - 4), src + (n - 4))
                }
            }

            if n >= 2 {
                return copy_u16_(dst, src) | copy_u16_(dst + (n - 2), src + (n - 2))
            }

            if n != 0 {
                var x = src[0]
                dst[0] = x
                acc    = x as usize
            }
        } else if n <= 2 * W {
            acc = copy_word_(dst, src) | copy_word_(
                dst + (n - W),
                src + (n - W),
            )
        } else if n <= 4 * W {
            acc = copy_word_(dst, src) | copy_word_(dst + W, src + W)
            acc |= copy_word_(dst + (n - 2 * W), src + (n - 2 * W))
            acc |= copy_word_(dst + (n - W), src + (n - W))
        } else {
            for var k: usize = 0; k < 4 * W; k += W {
                acc |= copy_word_(dst + k, src + k)
                acc |= copy_word_(dst + (n - 4 * W) + k, src + (n - 4 * W) + k)
            }
        }
    }

    return acc
}

/// Copies the `n <= 64` bytes at `src` to `dst` with no loop and no call:
/// 16 bytes from the front and 16 from the back, which overlap in the
/// middle, and the same again one step in when more than 32 remain; under
/// 16 bytes, two halves that overlap. `copy_short_` is the form that also
/// reports the bytes it copied.
///
/// \safety Both must be valid for `n` bytes and must not overlap.
priv inline fn copy_small_(dst: unsafe *u8, src: unsafe *const u8, n: usize) {
    unsafe {
        if n >= 16 {
            __builtin_copy(dst, src, 16)
            __builtin_copy(dst + (n - 16), src + (n - 16), 16)
            if n > 32 {
                __builtin_copy(dst + 16, src + 16, 16)
                __builtin_copy(dst + (n - 32), src + (n - 32), 16)
            }
        } else if n >= 8 {
            __builtin_copy(dst, src, 8)
            __builtin_copy(dst + (n - 8), src + (n - 8), 8)
        } else if n >= 4 {
            copy_u32_(dst, src)
            copy_u32_(dst + (n - 4), src + (n - 4))
        } else if n >= 2 {
            copy_u16_(dst, src)
            copy_u16_(dst + (n - 2), src + (n - 2))
        } else if n != 0 {
            dst[0] = src[0]
        }
    }
}

/// The word at `p`, any alignment.
///
/// \safety `p` must be valid for reads of W bytes.
priv inline fn load_word_unaligned_(p: unsafe *const u8) -> usize {
    var w: usize = 0
    unsafe {
        __builtin_copy(&w as unsafe *u8, p, W)
    }

    return w
}

/// 8, 4 or 2 bytes at `p`, any alignment, in the target's byte order: for
/// equality tests, where the order does not matter.
priv inline fn load_u64_(p: unsafe *const u8) -> u64 {
    var v: u64 = 0
    unsafe {
        __builtin_copy(&v as unsafe *u8, p, 8)
    }

    return v
}

priv inline fn load_u32_(p: unsafe *const u8) -> u32 {
    var v: u32 = 0
    unsafe {
        __builtin_copy(&v as unsafe *u8, p, 4)
    }

    return v
}

priv inline fn load_u16_(p: unsafe *const u8) -> u16 {
    var v: u16 = 0
    unsafe {
        __builtin_copy(&v as unsafe *u8, p, 2)
    }

    return v
}

/// The number of bytes from `p` up to the next W-aligned address; 0 when `p`
/// is aligned.
@pure priv inline fn to_aligned_(p: unsafe *const u8) -> usize {
    var a: usize = 0
    unsafe {
        a = p as usize
    }

    return (W - (a & (W - 1))) & (W - 1)
}

/// `c` in every byte.
@pure priv inline fn broadcast_(c: u8) -> usize {
    return (c as usize) * BYTE_ONES
}

/// True when some byte of `v` is zero. The mask behind this test can flag a
/// 0x01 byte that sits above a zero byte, so it answers "any", never "which".
@pure priv inline fn has_zero_(v: usize) -> bool {
    return ((v - BYTE_ONES) & ~v & BYTE_HIGHS) != 0
}

/// 0x80 in exactly the bytes of `v` that are zero. No carry crosses a byte,
/// so the mask can be searched from either end.
@pure priv inline fn zero_bytes_(v: usize) -> usize {
    return ~(((v & BYTE_LOW7) + BYTE_LOW7) | v | BYTE_LOW7)
}

/// Memory index of the first flagged byte of a nonzero `zero_bytes_` mask.
priv inline fn first_flag_(m: usize) -> usize {
    eval if defined!(__BIG_ENDIAN__) {
        return (__builtin_clz(m) >> 3) as usize
    } else {
        return (__builtin_ctz(m) >> 3) as usize
    }
}

/// Memory index of the last flagged byte of a nonzero `zero_bytes_` mask.
priv inline fn last_flag_(m: usize) -> usize {
    eval if defined!(__BIG_ENDIAN__) {
        return W - 1 - ((__builtin_ctz(m) >> 3) as usize)
    } else {
        return W - 1 - ((__builtin_clz(m) >> 3) as usize)
    }
}

/// A `zero_bytes_` mask without its first flagged byte, in memory order.
/// Each flag is the single bit 0x80 of its byte.
priv inline fn drop_first_flag_(m: usize) -> usize {
    eval if defined!(__BIG_ENDIAN__) {
        return m ^ ((1usize << (W * 8 - 1)) >> __builtin_clz(m))
    } else {
        return m & (m - 1)
    }
}

/// A `zero_bytes_` mask without its last flagged byte, in memory order.
priv inline fn drop_last_flag_(m: usize) -> usize {
    eval if defined!(__BIG_ENDIAN__) {
        return m & (m - 1)
    } else {
        return m ^ ((1usize << (W * 8 - 1)) >> __builtin_clz(m))
    }
}

// --- UTF-8 -------------------------------------------------------------------
//
// `validate_` is the only function here that accepts arbitrary bytes. The
// decoders take valid UTF-8, which is the string invariant, and trust the
// lead byte for the width.

/// Whether `b` is a continuation byte, 0x80..0xBF.
@pure priv inline fn is_cont_(b: u8) -> bool {
    return (b & 0xc0) == 0x80
}

/// Checks that the `n` bytes at `p` are well-formed UTF-8 (Unicode table
/// 3-7): no overlong form, no surrogate, nothing above U+10FFFF, no truncated
/// sequence.
///
/// Returns `(UTF8_OK, conts)`, where `conts` is the number of continuation
/// bytes (0 means every byte is ASCII), or `(i, _)` where `i` is the offset
/// of the lead byte of the first ill-formed sequence.
///
/// \safety `p` must be valid for reads of `n` bytes.
priv fn validate_(p: unsafe *const u8, n: usize) -> (usize, usize) {
    var conts: usize = 0
    var i:     usize = 0
    unsafe {
        while i < n {
            var b = p[i]
            if b < 0x80 {
                i += 1
                // Inside an ASCII run: once the cursor is aligned, skip
                // whole words that have no high bit set.
                if to_aligned_(p + i) == 0 {
                    while i + 2 * W <= n
                        && ((load_word_(p + i) | load_word_(p + i + W)) & BYTE_HIGHS) == 0 {
                        i += 2 * W
                    }

                    if i + W <= n && (load_word_(p + i) & BYTE_HIGHS) == 0 {
                        i += W
                    }
                }

                continue
            }

            if b < 0xc2 {
                // A continuation byte, or C0 / C1, which start only
                // overlong forms.
                return (i, 0)
            }

            if b < 0xe0 {
                if n - i < 2 || !is_cont_(p[i + 1]) {
                    return (i, 0)
                }

                i += 2
                conts += 1
                continue
            }

            if b < 0xf0 {
                if n - i < 3 {
                    return (i, 0)
                }

                var b1 = p[i + 1]
                // E0 A0..BF excludes overlong forms, ED 80..9F excludes
                // the surrogates.
                var lo: u8 = 0x80
                var hi: u8 = 0xbf
                if b == 0xe0 {
                    lo = 0xa0
                } else if b == 0xed {
                    hi = 0x9f
                }

                if b1 < lo || b1 > hi || !is_cont_(p[i + 2]) {
                    return (i, 0)
                }

                i += 3
                conts += 2
                continue
            }

            if b < 0xf5 {
                if n - i < 4 {
                    return (i, 0)
                }

                var b1 = p[i + 1]
                // F0 90..BF excludes overlong forms, F4 80..8F excludes
                // values above U+10FFFF.
                var lo: u8 = 0x80
                var hi: u8 = 0xbf
                if b == 0xf0 {
                    lo = 0x90
                } else if b == 0xf4 {
                    hi = 0x8f
                }

                if b1 < lo || b1 > hi || !is_cont_(p[i + 2]) || !is_cont_(p[i + 3]) {
                    return (i, 0)
                }

                i += 4
                conts += 3
                continue
            }

            // F5..FF never appear.
            return (i, 0)
        }
    }

    return (UTF8_OK, conts)
}

/// Whether every one of the `n` bytes at `p` is below 0x80.
///
/// \safety `p` must be valid for reads of `n` bytes.
@pure priv fn is_ascii_(p: unsafe *const u8, n: usize) -> bool {
    var i:   usize = 0
    var head       = to_aligned_(p)
    if head > n {
        head = n
    }

    unsafe {
        var acc: u8 = 0
        while i < head {
            acc |= p[i]
            i += 1
        }

        if acc >= 0x80 {
            return false
        }

        while i + 2 * W <= n {
            if ((load_word_(p + i) | load_word_(p + i + W)) & BYTE_HIGHS) != 0 {
                return false
            }

            i += 2 * W
        }

        if i + W <= n {
            if (load_word_(p + i) & BYTE_HIGHS) != 0 {
                return false
            }

            i += W
        }

        while i < n {
            acc |= p[i]
            i += 1
        }

        return acc < 0x80
    }
}

/// The number of continuation bytes in the `n` bytes at `p`; the codepoints
/// in valid UTF-8 are `n` minus that. One word per step and no population
/// count.
///
/// A continuation byte has bit 7 set and bit 6 clear, so
/// `(w >> 7) & ~(w >> 6) & BYTE_ONES` holds a 1 in each continuation byte's
/// lane. Lanes are summed over at most 255 words, which cannot carry out of
/// a byte, and each block is reduced with one multiply. The count does not
/// depend on byte order.
///
/// \safety `p` must be valid for reads of `n` bytes.
@pure priv fn count_conts_(p: unsafe *const u8, n: usize) -> usize {
    var conts: usize = 0
    var i:     usize = 0
    var head         = to_aligned_(p)
    if head > n {
        head = n
    }

    unsafe {
        while i < head {
            conts += ((p[i] & 0xc0) == 0x80) as usize
            i += 1
        }

        while i + W <= n {
            var words: usize = 255
            if n - i < 255 * W {
                words = (n - i) >> W_LOG2
            }

            var lanes: usize = 0
            for var k: usize = 0; k < words; k++ {
                var w = load_word_(p + i)
                lanes += (w >> 7) & ~(w >> 6) & BYTE_ONES
                i += W
            }

            // Fold the byte lanes pairwise into 16-bit lanes first: a full
            // block holds up to 255 * W, which one byte cannot.
            var pairs = (lanes & PAIR_LOWS) + ((lanes >> 8) & PAIR_LOWS)
            conts += (pairs * PAIR_ONES) >> (W * 8 - 16)
        }

        while i < n {
            conts += ((p[i] & 0xc0) == 0x80) as usize
            i += 1
        }
    }

    return conts
}

/// The length in bytes of the sequence a lead byte starts. `lead` is the
/// first byte of a char in valid UTF-8.
@pure priv inline fn width_(lead: u8) -> usize {
    @likely
    if lead < 0x80 {
        return 1
    }

    if lead < 0xe0 {
        return 2
    }

    if lead < 0xf0 {
        return 3
    }

    return 4
}

/// The scalar value `encode_` writes for `c`: `c` itself, or U+FFFD when `c`
/// is a surrogate or above U+10FFFF, which UTF-8 cannot carry.
@pure priv inline fn scalar_(c: char) -> u32 {
    var v: u32 = c
    @unlikely
    if v > 0x10ffff || (v >= 0xd800 && v < 0xe000) {
        return 0xfffd
    }

    return v
}

/// The number of bytes `c` encodes to.
@pure priv inline fn encoded_len_(c: char) -> usize {
    var v = scalar_(c)
    if v < 0x80 {
        return 1
    }

    if v < 0x800 {
        return 2
    }

    if v < 0x10000 {
        return 3
    }

    return 4
}

/// Writes the UTF-8 form of `c` at `out` and returns its length, 1 to 4.
///
/// \safety `out` must be valid for writes of `encoded_len_(c)` bytes.
priv inline fn encode_to_(c: char, out: unsafe *u8) -> usize {
    var v = scalar_(c)
    unsafe {
        @likely
        if v < 0x80 {
            out[0] = v as u8
            return 1
        }

        if v < 0x800 {
            out[0] = (0xc0 | (v >> 6)) as u8
            out[1] = (0x80 | (v & 0x3f)) as u8
            return 2
        }

        if v < 0x10000 {
            out[0] = (0xe0 | (v >> 12)) as u8
            out[1] = (0x80 | ((v >> 6) & 0x3f)) as u8
            out[2] = (0x80 | (v & 0x3f)) as u8
            return 3
        }

        out[0] = (0xf0 | (v >> 18)) as u8
        out[1] = (0x80 | ((v >> 12) & 0x3f)) as u8
        out[2] = (0x80 | ((v >> 6) & 0x3f)) as u8
        out[3] = (0x80 | (v & 0x3f)) as u8
        return 4
    }
}

/// The char that starts at `p` and its length in bytes.
///
/// \safety `p` must point at the first byte of a char in valid UTF-8; the
/// whole sequence is read and the continuation bytes are not re-checked.
@pure priv inline fn decode_(p: unsafe *const u8) -> (char, usize) {
    var v:   u32   = 0
    var len: usize = 1
    unsafe {
        var b: u32 = p[0]
        @likely
        if b < 0x80 {
            v = b
        } else if b < 0xe0 {
            v   = ((b & 0x1f) << 6) | ((p[1] & 0x3f) as u32)
            len = 2
        } else if b < 0xf0 {
            v   = ((b & 0x0f) << 12) | (((p[1] & 0x3f) as u32) << 6) | ((p[2] & 0x3f) as u32)
            len = 3
        } else {
            v = ((b & 0x07) << 18) | (((p[1] & 0x3f) as u32) << 12) | (((p[2] & 0x3f) as u32) << 6) | ((p[3] & 0x3f) as u32)
            len = 4
        }
    }

    var c: char = v
    return (c, len)
}

/// The char that ends just before `end` and its length in bytes: steps back
/// over at most three continuation bytes to the lead byte.
///
/// \safety `end` must point just past a char in valid UTF-8, so at least one
/// byte precedes it.
@pure priv inline fn decode_back_(end: unsafe *const u8) -> (char, usize) {
    var len: usize = 1
    unsafe {
        while ((end - len)[0] & 0xc0) == 0x80 {
            len += 1
        }

        return decode_(end - len)
    }
}

/// Whether `v` has the Unicode White_Space property.
@pure priv inline fn is_space_(c: char) -> bool {
    var v: u32 = c
    @likely
    if v < 0x80 {
        return v == 0x20 || (v >= 0x09 && v <= 0x0d)
    }

    if v == 0x85 || v == 0xa0 || v == 0x1680 {
        return true
    }

    if v >= 0x2000 && v <= 0x200a {
        return true
    }

    return v == 0x2028 || v == 0x2029 || v == 0x202f || v == 0x205f || v == 0x3000
}

pub eval NO_MATCH: usize = usize::MAX // start of the range a Pattern returns on a miss

// --- search -----------------------------------------------------------------
//
// Every function takes a pointer and a length and reads nothing outside the
// range. A miss is NO_MATCH.

/// Index of the first `c` in the `n` bytes at `p`.
///
/// \safety `p` must be valid for reads of `n` bytes.
priv fn find_byte_(p: unsafe *const u8, n: usize, c: u8) -> usize {
    var i:   usize = 0
    var head       = to_aligned_(p)
    if head > n {
        head = n
    }

    unsafe {
        while i < head {
            if p[i] == c {
                return i
            }

            i += 1
        }

        var bc = broadcast_(c)
        // Two words per step while neither holds the byte; the single-word
        // loop below then finds which.
        while i + 2 * W <= n {
            var x0 = load_word_(p + i) ^ bc
            var x1 = load_word_(p + i + W) ^ bc
            if ((((x0 - BYTE_ONES) & ~x0) | ((x1 - BYTE_ONES) & ~x1)) & BYTE_HIGHS) != 0 {
                break
            }

            i += 2 * W
        }

        while i + W <= n {
            var x = load_word_(p + i) ^ bc
            if has_zero_(x) {
                return i + first_flag_(zero_bytes_(x))
            }

            i += W
        }

        while i < n {
            if p[i] == c {
                return i
            }

            i += 1
        }
    }

    return NO_MATCH
}

/// Index of the last `c` in the `n` bytes at `p`.
///
/// \safety `p` must be valid for reads of `n` bytes.
priv fn rfind_byte_(p: unsafe *const u8, n: usize, c: u8) -> usize {
    var i = n
    unsafe {
        // Bytes past the last W-aligned address in the range.
        var tail = ((p + n) as usize) & (W - 1)
        if tail > n {
            tail = n
        }

        var stop = n - tail
        while i > stop {
            i -= 1
            if p[i] == c {
                return i
            }
        }

        var bc = broadcast_(c)
        while i >= 2 * W {
            var x0 = load_word_(p + (i - W)) ^ bc
            var x1 = load_word_(p + (i - 2 * W)) ^ bc
            if ((((x0 - BYTE_ONES) & ~x0) | ((x1 - BYTE_ONES) & ~x1)) & BYTE_HIGHS) != 0 {
                break
            }

            i -= 2 * W
        }

        while i >= W {
            var x = load_word_(p + (i - W)) ^ bc
            if has_zero_(x) {
                return i - W + last_flag_(zero_bytes_(x))
            }

            i -= W
        }

        while i > 0 {
            i -= 1
            if p[i] == c {
                return i
            }
        }
    }

    return NO_MATCH
}

/// Byte `i` of the `n` bytes at `p`, counted from the end when `rev`.
priv inline fn at_(p: unsafe *const u8, n: usize, i: isize, rev: bool) -> u8 {
    unsafe {
        if rev {
            return p[n - 1 - (i as usize)]
        }

        return p[i as usize]
    }
}

/// The maximal suffix of the needle under `<` (or under `>` when `greater`):
/// the index before its first byte, and its period.
priv fn max_suffix_(x: unsafe *const u8, m: usize, rev: bool, greater: bool) -> (isize, isize) {
    var ms: isize = -1
    var j:  isize = 0
    var k:  isize = 1
    var p:  isize = 1
    var mm        = m as isize
    while j + k < mm {
        var a      = at_(x, m, j + k, rev)
        var b      = at_(x, m, ms + k, rev)
        var before = a < b
        if greater {
            before = a > b
        }

        if before {
            j += k
            k = 1
            p = j - ms
        } else if a == b {
            if k != p {
                k += 1
            } else {
                j += p
                k = 1
            }
        } else {
            ms = j
            j  = ms + 1
            k  = 1
            p  = 1
        }
    }

    return (ms, p)
}

/// Two-Way search (Crochemore and Perrin): at most 2n + O(m) byte
/// comparisons for a needle of `m` bytes in `n`, and no table.
///
/// With `rev` both ranges are read back to front, so the result is the
/// distance from the END of the haystack to the end of the last match.
/// Requires 1 <= m <= n.
@no_inline priv fn two_way_(y:   unsafe *const u8,
                            n:   usize,
                            x:   unsafe *const u8,
                            m:   usize,
                            rev: bool) -> usize {
    var (i1, p1) = max_suffix_(x, m, rev, false)
    var (i2, p2) = max_suffix_(x, m, rev, true)
    var ell = i2
    var per = p2
    if i1 > i2 {
        ell = i1
        per = p1
    }

    var mm   = m as isize
    var last = (n - m) as isize

    // The period of the right part is at most its length, so ell + per < m.
    var periodic = true
    for var t: isize = 0; t <= ell; t++ {
        if at_(x, m, t, rev) != at_(x, m, t + per, rev) {
            periodic = false
            break
        }
    }

    var j: isize = 0
    if periodic {
        // `per` is the period of the whole needle. After a match of the
        // right part, the first m - per bytes at the next position are
        // already known to match.
        var memory: isize = -1
        while j <= last {
            var i = ell
            if memory > ell {
                i = memory
            }

            i += 1
            while i < mm && at_(x, m, i, rev) == at_(y, n, i + j, rev) {
                i += 1
            }


            if i >= mm {
                i = ell
                while i > memory && at_(x, m, i, rev) == at_(y, n, i + j, rev) {
                    i -= 1
                }


                if i <= memory {
                    return j as usize
                }

                j += per
                memory = mm - per - 1
            } else {
                j += i - ell
                memory = -1
            }
        }
    } else {
        // The needle's period is longer than either part, so a full shift
        // past the longer part is safe and nothing needs remembering.
        per = ell + 1
        if mm - ell - 1 > per {
            per = mm - ell - 1
        }

        per += 1
        while j <= last {
            var i = ell + 1
            while i < mm && at_(x, m, i, rev) == at_(y, n, i + j, rev) {
                i += 1
            }


            if i >= mm {
                i = ell
                while i >= 0 && at_(x, m, i, rev) == at_(y, n, i + j, rev) {
                    i -= 1
                }


                if i < 0 {
                    return j as usize
                }

                j += per
            } else {
                j += i - ell
            }
        }
    }

    return NO_MATCH
}

/// The byte comparisons a substring search may spend on rejected candidates
/// before it switches to Two-Way.
priv inline fn work_budget_(hay_len: usize) -> usize {
    if hay_len > (usize::MAX >> 3) {
        return usize::MAX
    }

    return hay_len * 8
}

/// Index of the first occurrence of the `nn` bytes at `nd` in the `hn` bytes
/// at `h`. An empty needle matches at 0.
///
/// A candidate is a position where the needle's first byte and its last
/// byte both match; its middle is then compared. The scan takes a word of
/// candidate starts at a time: the aligned word at the start, and the word
/// `nn - 1` bytes further on, which holds the bytes the last needle byte
/// has to match. Each rejected candidate is charged the bytes it could have
/// compared; past `8 * hn` the rest of the search is Two-Way, so the whole
/// search is O(hn + nn) whatever the input.
///
/// \safety `h` must be valid for reads of `hn` bytes and `nd` of `nn`.
priv fn find_bytes_(h: unsafe *const u8, hn: usize, nd: unsafe *const u8, nn: usize) -> usize {
    if nn == 0 {
        return 0
    }

    if nn > hn {
        return NO_MATCH
    }

    unsafe {
        if nn == 1 {
            return find_byte_(h, hn, nd[0])
        }

        var first = nd[0]
        var last  = nd[nn - 1]
        var back  = nn - 1
        // Candidate starts are [0, span); for each, the byte `back` further
        // on is in range.
        var span         = hn - back
        var budget       = work_budget_(hn)
        var work:  usize = 0
        var i:     usize = 0
        var head         = to_aligned_(h)
        if head > span {
            head = span
        }

        var bf = broadcast_(first)
        var bl = broadcast_(last)
        loop {
            // One byte at a time up to the first aligned word, and again
            // after the last whole word.
            while i < head {
                if h[i] == first && h[i + back] == last {
                    if nn == 2 || __builtin_compare_mem(h + i + 1, nd + 1, nn - 2) == 0 {
                        return i
                    }

                    work += back
                }

                i += 1
            }

            if head == span {
                break
            }

            while i + W <= span {
                // Two words of starts per step while neither holds a
                // candidate. A start is one where the first byte and the
                // byte `back` further on both match, which is a zero byte
                // of `x | y`: the test is exact, so the loop stops only at
                // a word with a real candidate.
                while i + 2 * W <= span {
                    var z0 = (load_word_(h + i) ^ bf) | (load_word_unaligned_(h + i + back) ^ bl)
                    var z1 = (load_word_(h + i + W) ^ bf) | (load_word_unaligned_(h + i + W + back) ^ bl)
                    var f0 = (z0 - BYTE_ONES) & ~z0
                    var f1 = (z1 - BYTE_ONES) & ~z1
                    if ((f0 | f1) & BYTE_HIGHS) != 0 {
                        break
                    }

                    i += 2 * W
                }

                if i + W > span {
                    break
                }

                var z = (load_word_(h + i) ^ bf) | (load_word_unaligned_(h + i + back) ^ bl)
                if has_zero_(z) {
                    var m = zero_bytes_(z)
                    while m != 0 {
                        var c = i + first_flag_(m)
                        if nn == 2 || __builtin_compare_mem(h + c + 1, nd + 1, nn - 2) == 0 {
                            return c
                        }

                        work += back
                        m = drop_first_flag_(m)
                    }

                    // The work only grows here, so this is where it is tested.
                    if work > budget {
                        i += W
                        break
                    }
                }

                i += W
            }

            if work > budget {
                break
            }

            head = span
        }


        if i >= span {
            return NO_MATCH
        }

        // Out of budget with candidates left: every start below i is
        // rejected.
        var r = two_way_(h + i, hn - i, nd, nn, false)
        if r == NO_MATCH {
            return NO_MATCH
        }

        return i + r
    }
}

/// Index of the last occurrence of the `nn` bytes at `nd` in the `hn` bytes
/// at `h`. An empty needle matches at `hn`.
///
/// The mirror of `find_bytes_`: it walks the positions of the needle's last
/// byte from the end, a word at a time, and has the same bound.
///
/// \safety `h` must be valid for reads of `hn` bytes and `nd` of `nn`.
priv fn rfind_bytes_(h: unsafe *const u8, hn: usize, nd: unsafe *const u8, nn: usize) -> usize {
    if nn == 0 {
        return hn
    }

    if nn > hn {
        return NO_MATCH
    }

    unsafe {
        if nn == 1 {
            return rfind_byte_(h, hn, nd[0])
        }

        var first        = nd[0]
        var last         = nd[nn - 1]
        var back         = nn - 1
        var budget       = work_budget_(hn)
        var work:  usize = 0
        // A candidate's last byte is at an index in [back, e); e only
        // shrinks.
        var e    = hn
        var tail = ((h + hn) as usize) & (W - 1)
        if tail > hn - back {
            tail = hn - back
        }

        var stop = hn - tail
        var bf   = broadcast_(first)
        var bl   = broadcast_(last)
        loop {
            while e > stop {
                e -= 1
                if h[e] == last && h[e - back] == first {
                    if nn == 2 || __builtin_compare_mem(h + (e - back) + 1, nd + 1, nn - 2) == 0 {
                        return e - back
                    }

                    work += back
                }
            }

            if stop == back {
                break
            }

            // h + e is aligned. A whole word of last-byte positions needs
            // e - W >= back, which also keeps the word of first bytes in
            // range.
            while e >= back + W {
                var x = load_word_(h + (e - W)) ^ bl
                var y = load_word_unaligned_(h + (e - W - back)) ^ bf
                // One test for both words: it can pass with no candidate
                // and never fails with one.
                if ((x - BYTE_ONES) & (y - BYTE_ONES) & ~(x | y) & BYTE_HIGHS) != 0 {
                    var m = zero_bytes_(x) & zero_bytes_(y)
                    while m != 0 {
                        var c = e - W - back + last_flag_(m)
                        if nn == 2 || __builtin_compare_mem(h + c + 1, nd + 1, nn - 2) == 0 {
                            return c
                        }

                        work += back
                        m = drop_last_flag_(m)
                    }

                    if work > budget {
                        e -= W
                        break
                    }
                }

                e -= W
            }

            if work > budget {
                break
            }

            stop = back
        }


        if e <= back {
            return NO_MATCH
        }

        // Out of budget with candidates left: they all end before e, so
        // they lie in the first e bytes.
        var r = two_way_(h, e, nd, nn, true)
        if r == NO_MATCH {
            return NO_MATCH
        }

        return e - nn - r
    }
}

/// `Pattern::find_in_` for a byte-string needle: the range of the first match
/// at or after byte `from`, or `(NO_MATCH, 0)`.
///
/// \safety As `find_bytes_`.
priv fn find_in_(h:    unsafe *const u8,
                 hn:   usize,
                 nd:   unsafe *const u8,
                 nn:   usize,
                 from: usize) -> (usize, usize) {
    if from > hn {
        return (NO_MATCH, 0)
    }

    var r: usize = 0
    unsafe {
        r = find_bytes_(h + from, hn - from, nd, nn)
    }

    if r == NO_MATCH {
        return (NO_MATCH, 0)
    }

    return (from + r, nn)
}

/// `Pattern::rfind_in_` for a byte-string needle: the range of the last match
/// ending at or before byte `to`, or `(NO_MATCH, 0)`. A `to` past the end is
/// the end.
///
/// \safety As `rfind_bytes_`.
priv fn rfind_in_(h:  unsafe *const u8,
                  hn: usize,
                  nd: unsafe *const u8,
                  nn: usize,
                  to: usize) -> (usize, usize) {
    var lim = to
    if lim > hn {
        lim = hn
    }

    var r = rfind_bytes_(h, lim, nd, nn)
    if r == NO_MATCH {
        return (NO_MATCH, 0)
    }

    return (r, nn)
}

/// Whether the `n <= 16` bytes at `a` and at `b` are equal: two loads per
/// side that overlap unless `n` is a power of two, and no call.
///
/// \safety Both pointers must be valid for reads of `n` bytes.
priv inline fn eq_short_(a: unsafe *const u8, b: unsafe *const u8, n: usize) -> bool {
    unsafe {
        if n >= 8 {
            var x = load_u64_(a) ^ load_u64_(b)
            var y = load_u64_(a + (n - 8)) ^ load_u64_(b + (n - 8))
            return (x | y) == 0
        }

        if n >= 4 {
            var x = load_u32_(a) ^ load_u32_(b)
            var y = load_u32_(a + (n - 4)) ^ load_u32_(b + (n - 4))
            return (x | y) == 0
        }

        if n >= 2 {
            var x = load_u16_(a) ^ load_u16_(b)
            var y = load_u16_(a + (n - 2)) ^ load_u16_(b + (n - 2))
            return (x | y) == 0
        }

        if n == 1 {
            return a[0] == b[0]
        }
    }

    return true
}

/// Whether the `n` bytes at `a` and at `b` are equal. The caller has already
/// compared the lengths.
///
/// \safety Both pointers must be valid for reads of `n` bytes.
priv inline fn eq_bytes_(a: unsafe *const u8, b: unsafe *const u8, n: usize) -> bool {
    if n <= 16 {
        return eq_short_(a, b, n)
    }

    unsafe {
        // 17 to 32 bytes: the first sixteen and the last sixteen, which
        // overlap unless n is 32. No branch on the bytes and no call.
        if n <= 32 {
            var x = load_u64_(a) ^ load_u64_(b)
            var y = load_u64_(a + 8) ^ load_u64_(b + 8)
            var z = load_u64_(a + (n - 16)) ^ load_u64_(b + (n - 16))
            var w = load_u64_(a + (n - 8)) ^ load_u64_(b + (n - 8))
            return ((x | y) | (z | w)) == 0
        }

        if a == b {
            return true
        }

        return __builtin_compare_mem(a, b, n) == 0
    }
}

/// A word loaded in the target's byte order, with its first byte in memory
/// most significant: an unsigned compare of two such words orders their
/// bytes.
priv inline fn first_byte_high_(w: usize) -> usize {
    eval if defined!(__BIG_ENDIAN__) {
        return w
    } else {
        return __builtin_bswap(w)
    }
}

/// The `0 < n < W` bytes at `p` as one integer that orders as the bytes do,
/// among keys built from the same `n`: the first half word and the last
/// half word (they overlap unless `n` is `W / 2`, and bytes that compare
/// equal in the first make the overlap equal in the second), or the first,
/// middle and last byte when `n` is below a half word.
///
/// \safety `p` must be valid for reads of `n` bytes.
priv inline fn short_key_(p: unsafe *const u8, n: usize) -> u64 {
    unsafe {
        eval if W == 8 {
            if n >= 4 {
                var hi = load_u32_(p)
                var lo = load_u32_(p + (n - 4))
                eval if !defined!(__BIG_ENDIAN__) {
                    hi = __builtin_bswap(hi)
                    lo = __builtin_bswap(lo)
                }

                return ((hi as u64) << 32) | (lo as u64)
            }
        }

        return ((p[0] as u64) << 16) | ((p[n >> 1] as u64) << 8) | (p[n - 1] as u64)
    }
}

/// How two lengths order once the common prefix has compared equal: the
/// shorter range is a proper prefix and orders first.
priv inline fn order_lengths_(an: usize, bn: usize) -> Ordering {
    var c = ((an > bn) as i8) - ((an < bn) as i8)
    if c < 0 {
        return Ordering::Less
    }

    if c > 0 {
        return Ordering::Greater
    }

    return Ordering::Equal
}

/// Three-way comparison of two byte ranges of which one is shorter than a
/// word: no load leaves the shorter range, and there is no call.
///
/// \safety `a` must be valid for reads of `an` bytes and `b` of `bn`.
priv inline fn compare_short_(a:  unsafe *const u8,
                              an: usize,
                              b:  unsafe *const u8,
                              bn: usize) -> Ordering {
    var n = an
    if bn < n {
        n = bn
    }

    if n != 0 {
        var x = short_key_(a, n)
        var y = short_key_(b, n)
        if x != y {
            return if x < y => Ordering::Less else => Ordering::Greater
        }
    }

    return order_lengths_(an, bn)
}

/// Three-way comparison of two byte ranges whose common prefix, `n` bytes,
/// is longer than five words, by the library's byte compare.
///
/// \safety `a` must be valid for reads of `an` bytes and `b` of `bn`; `n` is
/// the smaller of the two.
@no_inline priv fn compare_long_(a:  unsafe *const u8,
                                 an: usize,
                                 b:  unsafe *const u8,
                                 bn: usize,
                                 n:  usize) -> Ordering {
    var r: i32 = 0
    unsafe {
        r = __builtin_compare_mem(a, b, n)
    }

    if r != 0 {
        return if r < 0 => Ordering::Less else => Ordering::Greater
    }

    return order_lengths_(an, bn)
}

/// How two words that differ order, each read from the bytes of a string.
priv inline fn order_words_(x: usize, y: usize) -> Ordering {
    return if first_byte_high_(x) < first_byte_high_(y) => Ordering::Less
           else => Ordering::Greater
}

/// Three-way comparison of two strings' bytes, both at least a word long,
/// whose first words are equal; `ma` and `mb` are the two `meta` words.
/// Out of line, so that `op <=>` leaves one compare of two words in its
/// caller.
///
/// A common prefix of up to five words is compared here, a word at a time,
/// with no call, no loop and no frame: up to that length a load and a
/// compare per word cost less than the call into the library's byte
/// compare, however early the strings differ. The last word is read where
/// the prefix ends, and overlaps the word before it unless the prefix is a
/// whole number of words. A longer prefix leaves through a tail call.
///
/// \safety `a` and `b` must be valid for reads of `ma >> LEN_SHIFT` and
/// `mb >> LEN_SHIFT` bytes.
@no_inline priv fn compare_rest_(a:  unsafe *const u8,
                                 ma: usize,
                                 b:  unsafe *const u8,
                                 mb: usize) -> Ordering {
    var an = ma >> LEN_SHIFT
    var bn = mb >> LEN_SHIFT
    var n  = an
    if bn < n {
        n = bn
    }

    var x: usize = 0
    var y: usize = 0
    unsafe {
        if n > 2 * W {
            if n > 5 * W {
                return compare_long_(a, an, b, bn, n)
            }

            // The words between the first and the last, at most three.
            x = load_word_unaligned_(a + W)
            y = load_word_unaligned_(b + W)
            if x != y {
                return order_words_(x, y)
            }

            if n > 3 * W {
                x = load_word_unaligned_(a + 2 * W)
                y = load_word_unaligned_(b + 2 * W)
                if x != y {
                    return order_words_(x, y)
                }

                if n > 4 * W {
                    x = load_word_unaligned_(a + 3 * W)
                    y = load_word_unaligned_(b + 3 * W)
                    if x != y {
                        return order_words_(x, y)
                    }
                }
            }
        }

        x = load_word_unaligned_(a + (n - W))
        y = load_word_unaligned_(b + (n - W))
    }

    if x != y {
        return order_words_(x, y)
    }

    return order_lengths_(an, bn)
}

pub enum ParseErrorKind derives u8 {
    None,
    Empty,
    InvalidChar,
    Overflow,
    Trailing,
}

/// 8 bytes, so a panicking parse returns in registers.
pub struct ParseError {
    var at:   u32            // byte offset, saturating
    var kind: ParseErrorKind
}

extend ParseError {
    pub fn op panic (const self) -> string {
        var s = "parse error: "
        if self.kind == ParseErrorKind::Empty {
            s += "empty input"
            return s
        }

        if self.kind == ParseErrorKind::InvalidChar {
            s += "invalid character"
        } else if self.kind == ParseErrorKind::Overflow {
            s += "value out of range"
        } else if self.kind == ParseErrorKind::Trailing {
            s += "trailing characters"
        } else {
            s += "no error"
        }

        s += " at byte "
        // The offset in decimal, most significant digit first.
        var digits: [u8; 10] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        var v                = self.at
        var n:      usize    = 10
        loop {
            n -= 1
            digits[n] = 48 + ((v % 10) as u8)
            v /= 10
            if v == 0 {
                break
            }
        }

        s.push_ascii_(const &digits[n], 10 - n)
        return s
    }
}

/// Until a panicking requirement may return `Self`: the error comes back
/// through `err`, and `string::parse` turns a null into the panic.
pub interface FromStr {
    static fn from_str(const s: string, @inout err: ParseError) -> Self?
}

pub interface ToString {
    fn op as (const self) -> string
}

/// Formats into an existing string: no temporary, no allocation per value.
pub interface Append {
    fn append_to(const self, @inout out: string)
}

pub interface Pattern {
    /// Byte range of the first match at or after byte `from`; start is NO_MATCH on a miss.
    fn find_in(const self, const hay: string, from: usize) -> (usize, usize)
    /// Byte range of the last match ending at or before byte `to`; start is NO_MATCH on a miss.
    fn rfind_in(const self, const hay: string, to: usize) -> (usize, usize)
}

/// One type, three states, told apart by the low two bits of `meta`:
///   view     borrowed ptr + len, never freed, not NUL-terminated
///   literal  rodata, never freed, NUL-terminated;  [cp_len] sits just before the bytes
///   heap     owned, NUL-terminated;          [cap][conts] sit just before the bytes
/// Two words: 16 bytes on 64-bit, 8 on 32-bit. Length is `meta >> LEN_SHIFT`.
/// Every index is a byte offset. Slicing, trim and split return views and
/// never count: a view carries the ASCII bit of what it was cut from.
/// Codepoint count is O(1) for heap, literal and any ASCII view; a view of
/// non-ASCII text counts when asked, each time it is asked.
/// MOVE-ONLY: no copy ctor. Duplication is spelled out:
///   copy()      keeps the state (view -> view, literal -> literal: free; heap allocates)
///   to_owned()  always heap, except that a copy of the empty string is the empty literal
///   view()      borrows, never allocates
///
/// Invariants. The funnel accessors below rest on them, and every member
/// restores them before it returns:
///   1. `p` is never null. The empty string is the empty literal.
///   2. Bytes [0, len) are valid UTF-8.
///   3. If `meta & NUL_BIT`, `p[len] == 0`.
///   4. If heap: `len <= cap`, the block is `HDR + cap + 1` bytes aligned to
///      W and starts at `p - HDR`. `cap` is the word at `p - 2W`.
///   5. The ASCII bit set means every byte is below 0x80. Clear means unknown
///      for a view and "has a non-ASCII byte" for nothing: it is never set
///      on a guess and may stay clear on ASCII text.
///   6. If heap, the word at `p - W` is the exact number of continuation
///      bytes in [0, len): codepoints are `len` minus it, and an append of
///      ASCII bytes leaves it alone. If literal, the word at `p - W` is the
///      exact codepoint count, written by the compiler.
///   7. State 2 is never produced.
@relocatable
pub class string {
    priv union Ptr {
        var ro: *const u8? // view, literal
        var rw: *u8?       // heap
    }

    priv var p:    Self::Ptr // never null: the empty string is a literal
    priv var meta: usize     // bits 0..1 state, bit 2 ASCII, bits 3.. len in bytes

    // COMPILER-WORKAROUND(class-eval-init): a class constant initialized from
    // a file-level `eval` is not a constant expression in the emitted C++,
    // so HDR's value is written out.
    /// Bytes in front of a heap string's first byte, for `adopt_`.
    prot eval HEAP_HEADER_: usize = 2 * sizeof usize

    pub inline fn string(self) { // the empty literal
        unsafe {
            self.p.ro = (&EMPTY[1]) as unsafe *const u8 as *const u8
        }

        self.meta = ASCII_BIT | ST_LIT
    }

    // c/c++ conversions:
    pub inline fn string(self, c: unsafe *const __builtin_c_char) {
        unsafe {
            var unsafe *q       = c as unsafe *const u8
            var        n: usize = 0
            while q[n] != 0 {
                n += 1
            }

            self.init_bytes_(q, n)
        }
    }

    // `string(const c: *__builtin_c_char)` is not declared: a `const` parameter of
    // pointer type is a pointer to const in C++, the signature of the
    // `unsafe *const __builtin_c_char` form above.
    pub inline fn string(self, c: unsafe *__builtin_c_char) {
        unsafe {
            var unsafe *q       = c as unsafe *const u8
            var        n: usize = 0
            while q[n] != 0 {
                n += 1
            }

            self.init_bytes_(q, n)
        }
    }

    pub inline fn <S impl ByteRange> string(self, const s: S) { // copies s.size() bytes from s.data(); names no C++ type
        unsafe {
            self.init_bytes_(s.data() as unsafe *const u8, s.size())
        }
    }

    // kairo conversions:
    pub inline fn string(self, c: *const u8) { // NUL-terminated
        unsafe {
            var unsafe *q       = c as unsafe *const u8
            var        n: usize = 0
            while q[n] != 0 {
                n += 1
            }

            self.init_bytes_(q, n)
        }
    }

    pub inline fn string(self, const b: [const u8;]) { // copies all bytes
        var n = b.size()
        unsafe {
            if n == 0 {
                self.init_bytes_((&EMPTY[1]) as unsafe *const u8, 0)
            } else {
                self.init_bytes_(&b[0] as unsafe *const u8, n)
            }
        }
    }

    pub inline fn string(self, d: *const u8, n: usize) { // copies n bytes
        unsafe {
            self.init_bytes_(d as unsafe *const u8, n)
        }
    }

    pub fn string(self, c: char, n: usize) {
        var buf:   [u8; 4] = [0, 0, 0, 0]
        var w:     usize   = 0
        var total: usize   = 0
        unsafe {
            w = encode_to_(c, &buf[0] as unsafe *u8)
        }

        @unlikely
        if n == 0 {
            unsafe {
                self.p.ro = (&EMPTY[1]) as unsafe *const u8 as *const u8
            }

            self.meta = ASCII_BIT | ST_LIT
            return
        }

        @unlikely
        if __builtin_mul_overflow(w, n, &total) || total > MAX_LEN {
            string::too_long()
        }

        var unsafe *b = string::block_(total)
        unsafe {
            if w == 1 {
                __builtin_set_mem(b, buf[0] as byte, total)
            } else {
                for var i: usize = 0; i < total; i += w {
                    __builtin_copy(b + i, &buf[0] as unsafe *const u8, w)
                }
            }

            b[total]  = 0
            self.p.rw = b as *u8
        }

        self.meta = (total << LEN_SHIFT) | (if w == 1 => ASCII_BIT else => 0) | ST_HEAP
        unsafe {
            *self.hdr_conts() = total - n
        }
    }

    /// What a string literal lowers to; nothing else calls it. `lit` is the first
    /// byte of a rodata object `[cp_len: usize][bytes][0]`, `len` its byte count
    /// and `cp_len` its codepoint count, all three constants at the call.
    prot inline fn string(self, lit: *const u8, len: usize, cp_len: usize) {
        self.p.ro = lit
        self.meta = (len << LEN_SHIFT) | (if cp_len == len => ASCII_BIT else => 0) | ST_LIT
    }

    /// A view of `n` bytes at `p`, for the library's own buffers. Valid UTF-8 is
    /// the caller's to vouch for; the ASCII bit is left clear.
    prot static inline fn view_of_(p: *const u8, n: usize) -> string {
        var s = string()
        s.p.ro = p
        s.meta = (n << LEN_SHIFT) | ST_VIEW
        return s
    }

    /// A view of `n` ASCII bytes at `p` (a formatted number in a stack buffer):
    /// `out.push_str(string::ascii_view_(&buf[0], n))` appends them with no
    /// temporary allocation and no count. Every byte below 0x80 is the caller's
    /// to vouch for.
    prot static inline fn ascii_view_(p: *const u8, n: usize) -> string {
        var s = string()
        s.p.ro = p
        s.meta = (n << LEN_SHIFT) | ASCII_BIT | ST_VIEW
        return s
    }

    /// Appends the `n` ASCII bytes at `p`: `push_str(ascii_view_(p, n))`.
    prot inline fn push_ascii_(self, p: *const u8, n: usize) {
        self.push_str(string::ascii_view_(p, n))
    }

    /// The bytes `push_block_` copies whatever the text's length is.
    prot eval BLOCK_: usize = 24

    /// Appends the `n <= BLOCK_` ASCII bytes at `p`, which is valid for
    /// reads of `BLOCK_` bytes: what a number's text in a stack buffer is.
    /// With room for a whole block the copy has a constant size, two loads
    /// and two stores in place of a call; the bytes past the text land in
    /// spare capacity, behind the NUL.
    prot inline fn push_block_(self, p: *const u8, n: usize) {
        var m = self.meta
        @likely
        if (m & OWN_BIT) != 0 {
            var len = m >> LEN_SHIFT
            unsafe {
                @likely
                if len + string::BLOCK_ <= *self.hdr_cap() {
                    var unsafe *q = self.raw_mut() + len
                    __builtin_copy(q, p as unsafe *const u8, string::BLOCK_)
                    q[n]      = 0
                    self.meta = m + (n << LEN_SHIFT)
                    return
                }
            }
        }

        self.push_str(string::ascii_view_(p, n))
    }

    /// Takes over a block as a heap string. `bytes` is `HEAP_HEADER_` bytes
    /// into a block of `HEAP_HEADER_ + cap + 1` bytes from `alloc_raw`,
    /// aligned as `usize`; `len <= cap` bytes of valid UTF-8 holding `cps`
    /// codepoints start at `bytes`. Both header words and the NUL are written
    /// here.
    prot static inline fn adopt_(bytes: unsafe *u8, cap: usize, len: usize, cps: usize) -> string {
        var s = string()
        unsafe {
            bytes[len] = 0
            s.p.rw     = bytes as *u8
        }

        s.meta = (len << LEN_SHIFT) | (if cps == len => ASCII_BIT else => 0) | ST_HEAP
        unsafe {
            *s.hdr_cap()   = cap
            *s.hdr_conts() = len - cps
        }

        return s
    }

    /// Writes the UTF-8 form of `c` at `out` and returns its length, 1 to 4.
    /// A value that is not a Unicode scalar is written as U+FFFD.
    prot static inline fn encode_(c: char, out: unsafe *u8) -> usize {
        return encode_to_(c, out)
    }

    /// The char that starts at byte `b` and its length. `b` is below `size()`
    /// and on a char boundary; neither is checked.
    prot inline fn decode_at_(const self, b: usize) -> (char, usize) {
        unsafe {
            return decode_(self.raw() + b)
        }
    }

    /// The char that ends at byte `b` and its length. `b` is above 0, at most
    /// `size()` and on a char boundary; none of it is checked.
    prot inline fn decode_before_(const self, b: usize) -> (char, usize) {
        unsafe {
            return decode_back_(self.raw() + b)
        }
    }

    // --- the funnel: every other member reads the fields through these ---------

    // COMPILER-WORKAROUND(assume-narrowing): `@assume(p != null)` does not
    // narrow a `*T?`, so each accessor tests the field and ends the null
    // path with __builtin_unreachable.
    /// The first byte. Invariant 1: `p` is never null.
    @pure priv inline fn raw(const self) -> unsafe *const u8 {
        if self.p.ro? {
            unsafe {
                return self.p.ro as unsafe *const u8
            }
        }

        unsafe {
            __builtin_unreachable()
        }
    }

    /// The first byte of owned storage. Heap only (invariants 1 and 4).
    @pure priv inline fn raw_mut(const self) -> unsafe *u8 {
        if self.p.rw? {
            unsafe {
                return self.p.rw as unsafe *u8
            }
        }

        unsafe {
            __builtin_unreachable()
        }
    }

    /// The capacity word. Heap only (invariant 4).
    @pure priv inline fn hdr_cap(const self) -> unsafe *usize {
        unsafe {
            return (self.raw_mut() as unsafe *usize) - 2
        }
    }

    /// The continuation-byte count. Heap only (invariant 6).
    @pure priv inline fn hdr_conts(const self) -> unsafe *usize {
        unsafe {
            return (self.raw_mut() as unsafe *usize) - 1
        }
    }

    /// The codepoint count the compiler wrote. Literal only (invariant 6).
    @pure priv inline fn lit_cp(const self) -> usize {
        unsafe {
            return *((self.raw() as unsafe *const usize) - 1)
        }
    }

    // --- helpers ---------------------------------------------------------------

    /// A string of `meta` over the bytes at `p`; the caller vouches for every invariant.
    priv static inline fn make_(p: unsafe *const u8, meta: usize) -> string {
        var s = string()
        unsafe {
            s.p.ro = p as *const u8
        }

        s.meta = meta
        return s
    }

    /// The view of bytes [lo, hi), which the caller has checked.
    priv inline fn sub_(const self, lo: usize, hi: usize) -> string {
        unsafe {
            return string::make_(
                self.raw() + lo,
                ((hi - lo) << LEN_SHIFT) | (self.meta & ASCII_BIT) | ST_VIEW,
            )
        }
    }

    /// The continuation bytes in the string whose two words are `d` and `m`,
    /// whatever its state. It takes the words, not a string, so a caller
    /// that holds them in registers keeps them there.
    priv static inline fn conts_of_(d: unsafe *const u8, m: usize) -> usize {
        if (m & ASCII_BIT) != 0 {
            return 0
        }

        var n = m >> LEN_SHIFT
        unsafe {
            if (m & OWN_BIT) != 0 {
                return *((d as unsafe *const usize) - 1)
            }

            if (m & NUL_BIT) != 0 {
                return n - *((d as unsafe *const usize) - 1)
            }

            // Out of line: a caller keeps no frame for the scan of a
            // view that is not known to be ASCII.
            return n - string::scan_(d, n)
        }
    }

    /// The continuation bytes in this string, whatever its state.
    priv inline fn conts_(const self) -> usize {
        return string::conts_of_(self.raw(), self.meta)
    }

    /// Offset of `d` in this string's bytes when it points into [p, p + len],
    /// else NO_MATCH.
    priv inline fn offset_in_(const self, d: unsafe *const u8) -> usize {
        unsafe {
            var off = (d as usize) - (self.raw() as usize)
            if off <= (self.meta >> LEN_SHIFT) {
                return off
            }
        }

        return NO_MATCH
    }

    /// A heap block with room for `cap` bytes and the NUL; returns the first
    /// byte. The capacity word is written and the count word is zero.
    priv static inline fn block_(cap: usize) -> unsafe *u8 {
        var        total = HDR + cap + 1
        var unsafe *b    = alloc_raw(total, W)
        @unlikely
        if b == &null {
            oom(total, W)
        }

        unsafe {
            *(b as unsafe *usize)       = cap
            *((b as unsafe *usize) + 1) = 0
            return b + HDR
        }
    }

    /// A heap copy of the `n > 0` bytes at `d`, checked to be UTF-8: the two
    /// words of the string that owns it. Taken and returned by value, so the
    /// string under construction is never passed by address.
    priv static fn copy_checked_(d: unsafe *const u8, n: usize) -> (unsafe *u8, usize) {
        @unlikely
        if n > MAX_LEN {
            string::too_long()
        }

        var unsafe *b = string::block_(n)
        // Every byte ORed together: ASCII text has no high bit in it.
        var acc: usize = 0
        unsafe {
            if n <= 8 * W {
                acc = copy_short_(b, d, n)
            } else {
                // The source is tested, not the copy: a wide load of bytes
                // the copy has just stored waits for those stores. No early
                // exit, so the loop is a plain reduction the vectorizer takes.
                var words = n >> W_LOG2
                for var k: usize = 0; k < words; k++ {
                    acc |= load_word_unaligned_(d + (k << W_LOG2))
                }

                acc |= load_word_unaligned_(d + (n - W))
                __builtin_copy(b, d, n)
            }

            b[n] = 0
        }

        var conts: usize = 0
        @unlikely
        if (acc & BYTE_HIGHS) != 0 {
            var (bad, c) = validate_(b, n)
            if bad != UTF8_OK {
                unsafe {
                    free_raw(b - HDR, HDR + n + 1, W)
                }

                string::utf8_fail()
            }

            conts = c
            unsafe {
                *((b as unsafe *usize) - 1) = conts
            }
        }

        return (b, (n << LEN_SHIFT) | (if conts == 0 => ASCII_BIT else => 0) | ST_HEAP)
    }

    /// Sets this string, which owns nothing, to a copy of the `n` bytes at `d`
    /// and checks that they are UTF-8.
    priv inline fn init_bytes_(self, d: unsafe *const u8, n: usize) {
        if n == 0 {
            self.set_empty_()
            return
        }

        var (b, m) = string::copy_checked_(d, n)
        unsafe {
            self.p.rw = b as *u8
        }

        self.meta = m
    }

    /// A heap copy of the `n > 0` bytes at `d`, which are valid UTF-8 with
    /// `conts` continuation bytes, in a block of capacity `cap >= n`.
    priv static fn owned_(d: unsafe *const u8, n: usize, conts: usize, cap: usize) -> string {
        var unsafe *b = string::block_(cap)
        unsafe {
            if n <= 8 * W {
                copy_short_(b, d, n)
            } else {
                __builtin_copy(b, d, n)
            }

            b[n] = 0
        }

        var s = string()
        unsafe {
            s.p.rw = b as *u8
        }

        s.meta = (n << LEN_SHIFT) | (if conts == 0 => ASCII_BIT else => 0) | ST_HEAP
        unsafe {
            *s.hdr_conts() = conts
        }

        return s
    }

    /// `to_owned` of the string of at least one byte whose two words are
    /// `d` and `m`: a heap copy in a block exactly as long as the text.
    /// The words are taken by value: a view that exists only to be copied
    /// (`s[a..b].to_owned()`) is then never stored, and its destructor
    /// folds away. The bytes are a string's, so they are copied without a
    /// UTF-8 check.
    ///
    /// The paths that call anything but the allocator (a view that has to
    /// be counted, a copy longer than 64 bytes) leave through a call of
    /// their own, so the two words and the length are all that is live
    /// across the allocation and the common path saves three registers.
    priv static fn to_owned_(d: unsafe *const u8, m: usize) -> string {
        @unlikely
        if (m & (ASCII_BIT | NUL_BIT)) == 0 {
            return string::to_owned_counted_(d, m)
        }

        var        n  = m >> LEN_SHIFT
        var unsafe *b = alloc_raw(HDR + n + 1, W)
        @unlikely
        if b == &null {
            string::block_fail_(n)
        }

        // ASCII text keeps its length and ASCII bit as they are. Any other
        // literal or heap string stores its count in front of its bytes.
        var conts: usize = 0
        var meta         = m | ST_HEAP
        unsafe {
            if (m & ASCII_BIT) == 0 {
                var stored = *((d as unsafe *const usize) - 1)
                conts = (if (m & OWN_BIT) != 0 => stored else => n - stored)
                meta  = (n << LEN_SHIFT) | (if conts == 0 => ASCII_BIT else => 0) | ST_HEAP
            }

            *(b as unsafe *usize)       = n
            *((b as unsafe *usize) + 1) = conts
            b                           = b + HDR
            if n > 64 {
                return string::fill_long_(b, d, n, meta)
            }

            copy_small_(b, d, n)
            b[n] = 0
        }

        return string::make_(b, meta)
    }

    /// `to_owned_` of a view that is not known to be ASCII: its continuation
    /// bytes are counted on the way.
    @no_inline
    priv static fn to_owned_counted_(d: unsafe *const u8, m: usize) -> string {
        var n     = m >> LEN_SHIFT
        var conts = n - string::scan_(d, n)
        return string::owned_(d, n, conts, n)
    }

    /// The tail of a copy longer than 64 bytes into the block at `b`: the
    /// NUL, the bytes, and the string of `meta` over them. The NUL goes
    /// first, so `meta` and the block are all that is live across the copy.
    @no_inline
    priv static fn fill_long_(b: unsafe *u8, d: unsafe *const u8, n: usize, meta: usize) -> string {
        unsafe {
            b[n] = 0
            __builtin_copy(b, d, n)
        }

        return string::make_(b, meta)
    }

    /// No memory for a block of capacity `cap`.
    @cold_path @no_inline
    priv static fn block_fail_(cap: usize) -> ! {
        oom(HDR + cap + 1, W)
    }

    /// Frees the block. Heap only.
    priv inline fn free_block_(self) {
        unsafe {
            // A block holds its header and the NUL at least, so the size
            // is never the zero that free_raw tests for.
            var size = HDR + *self.hdr_cap() + 1
            __builtin_assume(size != 0)
            free_raw(self.raw_mut() - HDR, size, W)
        }
    }

    /// Hands both words to the caller and leaves the empty literal behind.
    priv inline fn release_(self) -> (unsafe *const u8, usize) {
        var r = (self.raw(), self.meta)
        self.set_empty_()
        return r
    }

    /// Makes this the empty literal without freeing anything.
    priv inline fn set_empty_(self) {
        unsafe {
            self.p.ro = (&EMPTY[1]) as unsafe *const u8 as *const u8
        }

        self.meta = ASCII_BIT | ST_LIT
    }

    /// Ends in heap state with room for `need` bytes; bytes, length, ASCII bit
    /// and count are kept. The block may move.
    priv inline fn grow_impl_(self, need: usize) {
        var m   = self.meta
        var len = m >> LEN_SHIFT
        @unlikely
        if need > MAX_LEN {
            string::too_long()
        }

        if (m & OWN_BIT) != 0 {
            var cap: usize = 0
            unsafe {
                cap = *self.hdr_cap()
            }

            var ncap = cap * 2
            if ncap < need {
                ncap = need
            }

            if ncap < MIN_CAP {
                ncap = MIN_CAP
            }

            if ncap > MAX_LEN {
                ncap = MAX_LEN
            }

            unsafe {
                var unsafe *nb = resize_raw(
                    self.raw_mut() - HDR,
                    HDR + cap + 1,
                    HDR + ncap + 1,
                    W,
                )

                @unlikely
                if nb == &null {
                    oom(HDR + ncap + 1, W)
                }

                *(nb as unsafe *usize) = ncap
                self.p.rw              = (nb + HDR) as *u8
            }

            return
        }

        var ncap = need
        if ncap < MIN_CAP {
            ncap = MIN_CAP
        }

        var        conts = self.conts_()
        var unsafe *b    = string::block_(ncap)
        unsafe {
            __builtin_copy(b, self.raw(), len)
            b[len]    = 0
            self.p.rw = b as *u8
        }

        self.meta = (m & ~STATE_MASK) | ST_HEAP
        unsafe {
            *self.hdr_conts() = conts
        }
    }

    /// Appends the `n` bytes at `d`, valid UTF-8 with `conts` continuation
    /// bytes. `d` may point into this string: it is followed if the block moves.
    priv fn append_raw_(self, d: unsafe *const u8, n: usize, conts: usize) {
        if n == 0 {
            return
        }

        var        m    = self.meta
        var        len  = m >> LEN_SHIFT
        var        nl   = len + n
        var unsafe *src = d
        var        fits = false
        if (m & OWN_BIT) != 0 {
            unsafe {
                fits = nl <= *self.hdr_cap()
            }
        }

        if !fits {
            var off = self.offset_in_(d)
            self.grow_impl_(nl)
            if off != NO_MATCH {
                unsafe {
                    src = self.raw() + off
                }
            }
        }

        unsafe {
            var unsafe *q = self.raw_mut()
            __builtin_copy(q + len, src, n)
            q[nl] = 0
            if conts != 0 {
                *self.hdr_conts() += conts
            }
        }

        self.meta = (nl << LEN_SHIFT) | (if conts == 0 => (self.meta & ASCII_BIT)
                                         else => 0) | ST_HEAP
    }

    /// `push_str` when the inline path does not apply: the string is not
    /// owned, the bytes do not fit, or `s` is not known to be ASCII.
    priv inline fn append_slow_impl_(self, d: unsafe *const u8, ometa: usize) {
        self.append_raw_(d, ometa >> LEN_SHIFT, string::conts_of_(d, ometa))
    }

    /// `push` when the inline path does not apply.
    priv inline fn push_slow_impl_(self, c: char) {
        var buf: [u8; 4] = [0, 0, 0, 0]
        unsafe {
            var w = encode_to_(c, &buf[0] as unsafe *u8)
            self.append_raw_(&buf[0] as unsafe *const u8, w, w - 1)
        }
    }

    // COMPILER-WORKAROUND(else-eval-if): `else eval if` is not accepted, so
    // the second test is nested.
    /// Length of the match of `p` that starts at byte `lo` and ends at or
    /// before `hi`, else NO_MATCH. A string or a char is compared in place;
    /// any other pattern is asked for its first match in [lo, hi), so a miss
    /// costs it a search of that range.
    priv fn <P impl Pattern> match_at_(const self, const p: P, lo: usize, hi: usize) -> usize {
        eval if __builtin_is_same<P, string>() {
            unsafe {
                var unsafe *s = &p as unsafe *const P as unsafe *const string
                var        m  = s->meta >> LEN_SHIFT
                if m <= hi - lo && eq_bytes_(self.raw() + lo, s->raw(), m) {
                    return m
                }
            }

            return NO_MATCH
        } else {
            eval if __builtin_is_same<P, char>() {
                var buf: [u8; 4] = [0, 0, 0, 0]
                unsafe {
                    var c = *(&p as unsafe *const P as unsafe *const char)
                    var m = encode_to_(c, &buf[0] as unsafe *u8)
                    if m <= hi - lo && eq_short_(self.raw() + lo, &buf[0] as unsafe *const u8, m) {
                        return m
                    }
                }

                return NO_MATCH
            } else {
                var v = self.sub_(lo, hi)
                var (a, m) = p.find_in(v, 0)
                if a == 0 {
                    return m
                }

                return NO_MATCH
            }
        }
    }

    /// Length of the match of `p` that ends at byte `hi` and starts at or
    /// after `lo`, else NO_MATCH. The mirror of `match_at_`.
    priv fn <P impl Pattern> match_before_(const self, const p: P, lo: usize, hi: usize) -> usize {
        eval if __builtin_is_same<P, string>() {
            unsafe {
                var unsafe *s = &p as unsafe *const P as unsafe *const string
                var        m  = s->meta >> LEN_SHIFT
                if m <= hi - lo && eq_bytes_(self.raw() + (hi - m), s->raw(), m) {
                    return m
                }
            }

            return NO_MATCH
        } else {
            eval if __builtin_is_same<P, char>() {
                var buf: [u8; 4] = [0, 0, 0, 0]
                unsafe {
                    var c = *(&p as unsafe *const P as unsafe *const char)
                    var m = encode_to_(c, &buf[0] as unsafe *u8)
                    if m <= hi - lo
                        && eq_short_(
                            self.raw() + (hi - m),
                            &buf[0] as unsafe *const u8,
                            m,
                        ) {
                        return m
                    }
                }

                return NO_MATCH
            } else {
                var v = self.sub_(lo, hi)
                var (a, m) = p.rfind_in(v, hi - lo)
                if a != NO_MATCH && a + m == hi - lo {
                    return m
                }

                return NO_MATCH
            }
        }
    }

    @move pub inline fn string(self, other: Self) { // bitwise; other becomes the empty literal
        self.p.ro = other.p.ro
        self.meta = other.meta
        unsafe {
            other.p.ro = (&EMPTY[1]) as unsafe *const u8 as *const u8
        }

        other.meta = ASCII_BIT | ST_LIT
    }

    pub inline fn op finally(self) { // frees only when heap
        if (self.meta & OWN_BIT) != 0 {
            self.free_block_()
        }
    }

    // Members, not extension members: a C++ template in a Native header
    // reads a string's bytes as `s.data()` / `s.size()`, and an extension
    // member emits as a free function that member lookup does not reach.
    @pure pub inline fn size(const self) -> usize { // bytes
        return self.meta >> LEN_SHIFT
    }

    @pure pub inline fn data(const self) -> *const u8 {
        unsafe {
            return self.raw() as *const u8
        }
    }

    @hot_path pub inline fn op [] (const self, b: usize) -> char { // char starting at byte b; traps off a boundary
        @unlikely
        if b >= (self.meta >> LEN_SHIFT) {
            string::index_fail_(b, self.meta >> LEN_SHIFT)
        }

        unsafe {
            var x = (self.raw() + b)[0]
            @likely
            if x < 0x80 {
                var c: char = x
                return c
            }

            // A tail call: a string indexed where it is ASCII keeps no
            // frame for the boundary test and the decoder.
            return string::index_wide_(self.raw() + b, b, self.meta >> LEN_SHIFT)
        }
    }

    /// `op []` at a byte of 0x80 or above, which is byte `b` of `len`: the
    /// char that starts there, or the trap when it is a continuation byte.
    @no_inline
    priv static fn index_wide_(p: unsafe *const u8, b: usize, len: usize) -> char {
        unsafe {
            @unlikely
            if (p[0] & 0xc0) == 0x80 {
                string::index_fail_(b, len)
            }
        }

        var (c, w) = decode_(p)
        return c
    }

    pub inline fn op [] (const self, r: Range<usize>) -> string { // view; traps off a boundary
        var hi = r.end
        if r.inclusive {
            @unlikely
            if hi == usize::MAX {
                range_fail(r.begin, hi, self.size())
            }

            hi += 1
        }

        return self.slice_(r.begin, hi)
    }

    pub inline fn op [] (const self, r: RangeFrom<usize>) -> string {
        return self.slice_(r.begin, self.size())
    }

    pub inline fn op [] (const self, r: RangeTo<usize>) -> string {
        var hi = r.end
        if r.inclusive {
            @unlikely
            if hi == usize::MAX {
                range_fail(0, hi, self.size())
            }

            hi += 1
        }

        return self.slice_(0, hi)
    }

    /// The view of bytes [lo, hi) after the range and both boundaries are
    /// checked. ASCII text has a boundary at every offset, so its check is
    /// the one test of the bit; offset 0 and the end are boundaries of any
    /// text.
    priv inline fn slice_(const self, lo: usize, hi: usize) -> string {
        var m   = self.meta
        var len = m >> LEN_SHIFT
        @unlikely
        if lo > hi || hi > len {
            range_fail(lo, hi, len)
        }

        @unlikely
        if (m & ASCII_BIT) == 0 {
            unsafe {
                var unsafe *q = self.raw()
                // A continuation byte is below -0x40 as a signed byte.
                // `lo == len` leaves `hi == len` and reads nothing.
                @unlikely
                if lo != 0 && lo != len && (q[lo] as i8) < -0x40 {
                    string::index_fail_(lo, len)
                }

                @unlikely
                if hi != len && (q[hi] as i8) < -0x40 {
                    string::index_fail_(hi, len)
                }
            }
        }

        return self.sub_(lo, hi)
    }

    pub fn op in (const self) -> yield char {
        var        i: usize = 0
        var        n        = self.size()
        var unsafe *q       = self.raw()
        while i < n {
            unsafe {
                var (c, w) = decode_(q + i)
                i += w
                yield c
            }
        }
    }

    @hot_path pub inline fn op += (self, const o: string) { // a + b is derived: MOVES a, then +=
        self.push_str(o)
    }

    // slow paths, kept out of every inlined caller. The one fast path is
    // heap with room; view, literal and a full heap buffer land here.
    //
    // The two that `push` and `push_str` reach take the string's two words
    // by value and return the new ones. The address of the string is then
    // never passed, so a caller's loop keeps both words in registers.
    //
    // Text that is not known to be ASCII lands in them on every append, so
    // each first extends an owned string with room in place: `append_slow_`
    // copies up to two words as overlapping loads, `push_slow_` encodes the
    // char where it goes. They call nothing on that path and leave through
    // a tail call otherwise, so they save only the registers they use. The
    // bodies are written twice because the attribute differs.
    eval if defined!(__x86_64__) || defined!(__aarch64__) {
        @cold_path @preserve_most @no_inline
        priv fn grow(self, need: usize) {    // view/literal -> heap, or realloc geometric
            self.grow_impl_(need)
        }

        @cold_path @preserve_most @no_inline
        priv fn make_owned(self) {    // view/literal -> heap, exact size + NUL
            self.grow_impl_(self.meta >> LEN_SHIFT)
        }

        @preserve_most @no_inline
        priv static fn append_slow_(p:     unsafe *const u8,
                                    meta:  usize,
                                    d:     unsafe *const u8,
                                    ometa: usize) -> (unsafe *const u8, usize) {
            var n   = ometa >> LEN_SHIFT
            var len = meta >> LEN_SHIFT
            // Owned, short, and counted without a scan (ASCII, a literal
            // or a heap string): extended in place.
            if (meta & OWN_BIT) != 0 && n <= 2 * W && (ometa & (ASCII_BIT | NUL_BIT)) != 0 {
                unsafe {
                    var unsafe *q = p as unsafe *u8
                    if len + n <= *((q as unsafe *usize) - 2) {
                        var conts: usize = 0
                        if (ometa & ASCII_BIT) == 0 {
                            conts = *((d as unsafe *const usize) - 1)
                            if (ometa & OWN_BIT) == 0 {
                                conts = n - conts
                            }
                        }

                        copy_short_(q + len, d, n)
                        q[len + n] = 0
                        var bits = meta & ASCII_BIT
                        if conts != 0 {
                            *((q as unsafe *usize) - 1) += conts
                            bits = 0
                        }

                        return (p, ((len + n) << LEN_SHIFT) | bits | ST_HEAP)
                    }
                }
            }

            return string::append_cold_(p, meta, d, ometa)
        }

        @preserve_most @no_inline
        priv static fn push_slow_(p: unsafe *const u8, meta: usize, c: char) -> (unsafe *const u8, usize) {
            var len = meta >> LEN_SHIFT
            // Owned with room for any char: encoded where it goes.
            if (meta & OWN_BIT) != 0 {
                unsafe {
                    var unsafe *q = p as unsafe *u8
                    if len + 4 <= *((q as unsafe *usize) - 2) {
                        var w = encode_to_(c, q + len)
                        q[len + w] = 0
                        var bits = meta & ASCII_BIT
                        if w != 1 {
                            *((q as unsafe *usize) - 1) += w - 1
                            bits = 0
                        }

                        return (p, ((len + w) << LEN_SHIFT) | bits | ST_HEAP)
                    }
                }
            }

            return string::push_cold_(p, meta, c)
        }

        @cold_path @preserve_most @no_inline
        priv static fn append_cold_(p:     unsafe *const u8,
                                    meta:  usize,
                                    d:     unsafe *const u8,
                                    ometa: usize) -> (unsafe *const u8, usize) {
            var s = string::make_(p, meta)
            s.append_slow_impl_(d, ometa)
            return s.release_()
        }

        @cold_path @preserve_most @no_inline
        priv static fn push_cold_(p: unsafe *const u8, meta: usize, c: char) -> (unsafe *const u8, usize) {
            var s = string::make_(p, meta)
            s.push_slow_impl_(c)
            return s.release_()
        }

        @cold_path @preserve_most @no_inline
        priv static fn promote_(p: unsafe *const u8, meta: usize) -> (unsafe *const u8, usize) {
            var s = string::make_(p, meta)
            s.grow_impl_(meta >> LEN_SHIFT)
            return s.release_()
        }
    } else {
        @cold_path @no_inline
        priv fn grow(self, need: usize) {    // view/literal -> heap, or realloc geometric
            self.grow_impl_(need)
        }

        @cold_path @no_inline
        priv fn make_owned(self) {    // view/literal -> heap, exact size + NUL
            self.grow_impl_(self.meta >> LEN_SHIFT)
        }

        @no_inline
        priv static fn append_slow_(p:     unsafe *const u8,
                                    meta:  usize,
                                    d:     unsafe *const u8,
                                    ometa: usize) -> (unsafe *const u8, usize) {
            var n   = ometa >> LEN_SHIFT
            var len = meta >> LEN_SHIFT
            // Owned, short, and counted without a scan (ASCII, a literal
            // or a heap string): extended in place.
            if (meta & OWN_BIT) != 0 && n <= 2 * W && (ometa & (ASCII_BIT | NUL_BIT)) != 0 {
                unsafe {
                    var unsafe *q = p as unsafe *u8
                    if len + n <= *((q as unsafe *usize) - 2) {
                        var conts: usize = 0
                        if (ometa & ASCII_BIT) == 0 {
                            conts = *((d as unsafe *const usize) - 1)
                            if (ometa & OWN_BIT) == 0 {
                                conts = n - conts
                            }
                        }

                        copy_short_(q + len, d, n)
                        q[len + n] = 0
                        var bits = meta & ASCII_BIT
                        if conts != 0 {
                            *((q as unsafe *usize) - 1) += conts
                            bits = 0
                        }

                        return (p, ((len + n) << LEN_SHIFT) | bits | ST_HEAP)
                    }
                }
            }

            return string::append_cold_(p, meta, d, ometa)
        }

        @no_inline
        priv static fn push_slow_(p: unsafe *const u8, meta: usize, c: char) -> (unsafe *const u8, usize) {
            var len = meta >> LEN_SHIFT
            // Owned with room for any char: encoded where it goes.
            if (meta & OWN_BIT) != 0 {
                unsafe {
                    var unsafe *q = p as unsafe *u8
                    if len + 4 <= *((q as unsafe *usize) - 2) {
                        var w = encode_to_(c, q + len)
                        q[len + w] = 0
                        var bits = meta & ASCII_BIT
                        if w != 1 {
                            *((q as unsafe *usize) - 1) += w - 1
                            bits = 0
                        }

                        return (p, ((len + w) << LEN_SHIFT) | bits | ST_HEAP)
                    }
                }
            }

            return string::push_cold_(p, meta, c)
        }

        @cold_path @no_inline
        priv static fn append_cold_(p:     unsafe *const u8,
                                    meta:  usize,
                                    d:     unsafe *const u8,
                                    ometa: usize) -> (unsafe *const u8, usize) {
            var s = string::make_(p, meta)
            s.append_slow_impl_(d, ometa)
            return s.release_()
        }

        @cold_path @no_inline
        priv static fn push_cold_(p: unsafe *const u8, meta: usize, c: char) -> (unsafe *const u8, usize) {
            var s = string::make_(p, meta)
            s.push_slow_impl_(c)
            return s.release_()
        }

        @cold_path @no_inline
        priv static fn promote_(p: unsafe *const u8, meta: usize) -> (unsafe *const u8, usize) {
            var s = string::make_(p, meta)
            s.grow_impl_(meta >> LEN_SHIFT)
            return s.release_()
        }
    }

    @pure @no_inline
    priv fn scan_codepoints(const self) -> usize { // a view without the ASCII bit
        return string::scan_(self.raw(), self.meta >> LEN_SHIFT)
    }

    @cold_path @no_inline
    priv fn boundary_fail(const self, b: usize) -> ! { // off a char boundary or out of range
        if b > (self.meta >> LEN_SHIFT) {
            index_fail(b, self.meta >> LEN_SHIFT)
        }

        char_boundary_fail(b, self.meta >> LEN_SHIFT)
    }

    @cold_path @no_inline
    priv static fn too_long() -> ! { // length would pass MAX_LEN
        __builtin_trap()
    }

    /// `op []` off a char boundary or out of range, for the inlined members:
    /// it takes no `self`, so a string that is only indexed stays in registers.
    @cold_path @no_inline
    priv static fn index_fail_(b: usize, len: usize) -> ! {
        if b >= len {
            index_fail(b, len)
        }

        char_boundary_fail(b, len)
    }

    /// The codepoints in the `n` bytes at `p`, for the inlined `codepoints`.
    @pure @no_inline
    priv static fn scan_(p: unsafe *const u8, n: usize) -> usize {
        return n - count_conts_(p, n)
    }

    /// Bytes that are not UTF-8 reached a constructor.
    @cold_path @no_inline
    priv static fn utf8_fail() -> ! {
        __builtin_trap()
    }
}

extend string impl Eq {
    inline fn op == (const self, const o: string) -> bool {
        var n = self.meta >> LEN_SHIFT
        if n != (o.meta >> LEN_SHIFT) {
            return false
        }

        return eq_bytes_(self.raw(), o.raw(), n)
    }
}

extend string impl Ord {
    /// Byte order, which for UTF-8 is codepoint order; a proper prefix
    /// orders first. Two strings of at least a word each that differ in
    /// their first word are ordered by one compare of those words, each
    /// read as an integer: no call and no loop.
    inline fn op <=> (const self, const o: string) -> Ordering {
        var        ma = self.meta
        var        mb = o.meta
        var unsafe *a = self.raw()
        var unsafe *b = o.raw()
        @likely
        if ma >= WORD_META && mb >= WORD_META {
            var x = load_word_unaligned_(a)
            var y = load_word_unaligned_(b)
            @likely
            if x != y {
                return if first_byte_high_(x) < first_byte_high_(y) => Ordering::Less
                       else => Ordering::Greater
            }

            return compare_rest_(a, ma, b, mb)
        }

        return compare_short_(a, ma >> LEN_SHIFT, b, mb >> LEN_SHIFT)
    }
}

extend string impl Hash {
    /// Only the bytes and their count reach the hasher: a view, a literal and
    /// a heap string of the same text hash alike.
    inline fn hash(const self, @inout h: Hasher) {
        h.write(self.bytes())
    }
}

extend string impl Default {
    static inline fn make_default() -> string {
        return string()
    }
}

extend string impl Append {
    inline fn append_to(const self, @inout out: string) {
        out.push_str(self)
    }
}

extend string impl Pattern {
    inline fn find_in(const self, const hay: string, from: usize) -> (usize, usize) {
        return find_in_(hay.raw(), hay.size(), self.raw(), self.size(), from)
    }

    inline fn rfind_in(const self, const hay: string, to: usize) -> (usize, usize) {
        return rfind_in_(hay.raw(), hay.size(), self.raw(), self.size(), to)
    }
}

extend string {
    pub static fn with_capacity(n: usize) -> string {
        var s = string()
        if n == 0 {
            return s
        }

        @unlikely
        if n > MAX_LEN {
            string::too_long()
        }

        var unsafe *b = string::block_(n)
        unsafe {
            b[0]   = 0
            s.p.rw = b as *u8
        }

        s.meta = ASCII_BIT | ST_HEAP
        return s
    }

    /// A copy of the `n` bytes at `d`, not checked to be UTF-8. The caller accepts
    /// that the bytes may not be UTF-8: source text, argv and paths that must
    /// round-trip. Such a string is for storing, comparing and printing back;
    /// character iteration over invalid bytes is not meaningful.
    pub static fn from_bytes_unchecked(d: *const u8, n: usize) -> string {
        if n == 0 {
            return string()
        }

        @unlikely
        if n > MAX_LEN {
            string::too_long()
        }

        // Continuation bytes counted as a valid string's would be.
        var conts: usize = 0
        unsafe {
            for var i: usize = 0; i < n; i++ {
                if (d[i] & 0xC0) == 0x80 {
                    conts++
                }
            }

            return string::owned_(d as unsafe *const u8, n, conts, n)
        }
    }

    pub static fn from_utf8(const b: [const u8;]) -> string? { // null on invalid UTF-8
        var n = b.size()
        if n == 0 {
            return string()
        }

        if n > MAX_LEN {
            return null
        }

        unsafe {
            var unsafe *d = &b[0] as unsafe *const u8
            var (bad, conts) = validate_(d, n)
            if bad != UTF8_OK {
                return null
            }

            return string::owned_(d, n, conts, n)
        }
    }

    // state
    pub inline fn copy(const self) -> string { // keeps the state
        var m = self.meta
        if (m & OWN_BIT) != 0 {
            var n = m >> LEN_SHIFT
            if n == 0 {
                return string()
            }

            return string::to_owned_(self.raw(), m)
        }

        return string::make_(self.raw(), m)
    }

    pub inline fn to_owned(const self) -> string {
        var m = self.meta
        if (m >> LEN_SHIFT) == 0 {
            return string()
        }

        return string::to_owned_(self.raw(), m)
    }

    pub inline fn view(const self) -> string {
        return string::make_(self.raw(), (self.meta & ~STATE_MASK) | ST_VIEW)
    }

    @pure pub inline fn is_owned(const self) -> bool { // heap
        return (self.meta & OWN_BIT) != 0
    }

    @pure pub inline fn is_view(const self) -> bool { // borrowed, not a literal
        return (self.meta & NUL_BIT) == 0
    }

    @pure pub inline fn is_static(const self) -> bool { // a literal
        return (self.meta & STATE_MASK) == ST_LIT
    }

    // size
    @pure pub inline fn codepoints(const self) -> usize { // O(1), except a non-ASCII view: O(n)
        var m = self.meta
        // Invariant 6: a heap string's count word is exact whether or not
        // the ASCII bit is set, so one test leads to a load and a subtract.
        if (m & OWN_BIT) != 0 {
            unsafe {
                return (m >> LEN_SHIFT) - *self.hdr_conts()
            }
        }

        if (m & ASCII_BIT) != 0 {
            return m >> LEN_SHIFT
        }

        if (m & NUL_BIT) != 0 {
            return self.lit_cp()
        }

        return string::scan_(self.raw(), m >> LEN_SHIFT)
    }

    @pure pub inline fn is_empty(const self) -> bool {
        return (self.meta >> LEN_SHIFT) == 0
    }

    @pure pub inline fn is_ascii(const self) -> bool { // O(1), except a non-ASCII view: O(n)
        var m = self.meta
        @likely
        if (m & ASCII_BIT) != 0 {
            return true
        }

        if (m & OWN_BIT) != 0 {
            unsafe {
                return *self.hdr_conts() == 0
            }
        }

        if (m & NUL_BIT) != 0 {
            return self.lit_cp() == (m >> LEN_SHIFT)
        }

        return is_ascii_(self.raw(), m >> LEN_SHIFT)
    }

    @pure pub inline fn capacity(const self) -> usize { // 0 unless heap
        if (self.meta & OWN_BIT) != 0 {
            unsafe {
                return *self.hdr_cap()
            }
        }

        return 0
    }

    /// Room for at least `bytes` bytes in all, without another allocation.
    pub fn reserve(self, bytes: usize) {
        // Room for nothing is what a view or a literal already has.
        if bytes == 0 {
            return
        }

        if (self.meta & OWN_BIT) != 0 {
            unsafe {
                if bytes <= *self.hdr_cap() {
                    return
                }
            }
        }

        var need = bytes
        if need < (self.meta >> LEN_SHIFT) {
            need = self.meta >> LEN_SHIFT
        }

        self.grow(need)
    }

    /// Gives back the capacity past the length. An empty string gives back
    /// its whole block.
    pub fn shrink_to_fit(self) {
        var m = self.meta
        if (m & OWN_BIT) == 0 {
            return
        }

        var len = m >> LEN_SHIFT
        if len == 0 {
            self.free_block_()
            self.set_empty_()
            return
        }

        unsafe {
            var cap = *self.hdr_cap()
            if cap == len {
                return
            }

            var unsafe *nb = resize_raw(
                self.raw_mut() - HDR,
                HDR + cap + 1,
                HDR + len + 1,
                W,
            )

            // A refused shrink leaves the block as it is.
            if nb != &null {
                *(nb as unsafe *usize) = len
                self.p.rw              = (nb + HDR) as *u8
            }
        }
    }

    // access
    @pure pub inline fn get(const self, b: usize) -> char? {
        if b >= (self.meta >> LEN_SHIFT) {
            return null
        }

        unsafe {
            var unsafe *q = self.raw() + b
            if (q[0] & 0xc0) == 0x80 {
                return null
            }

            var (c, w) = decode_(q)
            return c
        }
    }

    @pure pub fn char_at(const self, cp: usize) -> char? { // O(1) if ASCII, else O(n)
        var        m  = self.meta
        var        n  = m >> LEN_SHIFT
        var unsafe *q = self.raw()
        unsafe {
            if (m & ASCII_BIT) != 0 {
                if cp >= n {
                    return null
                }

                var c: char = q[cp]
                return c
            }

            var i: usize = 0
            var k: usize = 0
            while i < n {
                if k == cp {
                    var (c, w) = decode_(q + i)
                    return c
                }

                i += width_(q[i])
                k += 1
            }
        }

        return null
    }

    @pure pub fn byte_offset(const self, cp: usize) -> usize? { // O(1) if ASCII, else O(n)
        var        m  = self.meta
        var        n  = m >> LEN_SHIFT
        var unsafe *q = self.raw()
        if (m & ASCII_BIT) != 0 {
            if cp > n {
                return null
            }

            return cp
        }

        var i: usize = 0
        var k: usize = 0
        unsafe {
            while i < n {
                if k == cp {
                    return i
                }

                i += width_(q[i])
                k += 1
            }
        }

        if k == cp {
            return n
        }

        return null
    }

    @pure pub inline fn first(const self) -> char? {
        if (self.meta >> LEN_SHIFT) == 0 {
            return null
        }

        var (c, w) = decode_(self.raw())
        return c
    }

    @pure pub inline fn last(const self) -> char? {
        var n = self.meta >> LEN_SHIFT
        if n == 0 {
            return null
        }

        unsafe {
            var (c, w) = decode_back_(self.raw() + n)
            return c
        }
    }

    @pure pub inline fn is_char_boundary(const self, b: usize) -> bool {
        var m = self.meta
        var n = m >> LEN_SHIFT
        if b >= n {
            return b == n
        }

        if (m & ASCII_BIT) != 0 {
            return true
        }

        // Everything but a continuation byte is -0x40 or more as a signed byte.
        unsafe {
            return ((self.raw() + b)[0] as i8) >= -0x40
        }
    }

    // raw
    pub inline fn bytes(const self) -> [const u8;] {
        return Slice<const u8>(self.raw(), self.meta >> LEN_SHIFT)
    }

    pub inline fn c_str(self) -> unsafe *const __builtin_c_char { // a view becomes heap first
        @unlikely
        if (self.meta & NUL_BIT) == 0 {
            var (np, nm) = string::promote_(self.raw(), self.meta)
            unsafe {
                self.p.rw = np as unsafe *u8 as *u8
            }

            self.meta = nm
        }

        unsafe {
            return self.raw() as unsafe *const __builtin_c_char
        }
    }

    @pure pub inline fn try_c_str(const self) -> (unsafe *const __builtin_c_char)? { // null on a view; never allocates
        if (self.meta & NUL_BIT) == 0 {
            return null
        }

        unsafe {
            return self.raw() as unsafe *const __builtin_c_char
        }
    }

    // iteration
    pub inline fn chars(const self) -> Chars {
        unsafe {
            return Chars(self.raw() as *const u8, self.meta >> LEN_SHIFT)
        }
    }

    pub fn char_indices(const self) -> yield (usize, char) {
        var        i: usize = 0
        var        n        = self.size()
        var unsafe *q       = self.raw()
        while i < n {
            unsafe {
                var (c, w) = decode_(q + i)
                var at = i
                i += w
                yield (at, c)
            }
        }
    }

    /// The lines, without their terminators: a line ends at `\n`, and one
    /// `\r` before it is dropped. Text after the last `\n` is a line; nothing
    /// after it is not.
    pub fn lines(const self) -> yield string {
        var        i: usize = 0
        var        n        = self.size()
        var unsafe *q       = self.raw()
        while i < n {
            var end  = n
            var next = n
            unsafe {
                var j = find_byte_(q + i, n - i, 10)
                if j != NO_MATCH {
                    end  = i + j
                    next = end + 1
                    // The `\r` of a `\r\n` goes with it.
                    if end > i && q[end - 1] == 13 {
                        end -= 1
                    }
                }
            }

            var at = i
            i = next
            yield self.sub_(at, end)
        }
    }

    /// The runs of text between Unicode white space; never an empty one.
    pub fn fields(const self) -> yield string {
        var        i: usize = 0
        var        n        = self.size()
        var unsafe *q       = self.raw()
        while i < n {
            unsafe {
                var (c, w) = decode_(q + i)
                if is_space_(c) {
                    i += w
                    continue
                }

                var start = i
                while i < n {
                    var (d, x) = decode_(q + i)
                    if is_space_(d) {
                        break
                    }

                    i += x
                }

                yield self.sub_(start, i)
            }
        }
    }

    /// The byte after the char that starts at `b`, or one past the end when
    /// `b` is the end: where a search resumes after an empty match at `b`.
    priv inline fn step_(const self, b: usize) -> usize {
        if b >= (self.meta >> LEN_SHIFT) {
            return b + 1
        }

        unsafe {
            return b + width_((self.raw() + b)[0])
        }
    }

    // search, byte offsets
    pub fn <P impl Pattern> op in (const self, const p: P) -> bool {
        var (a, m) = p.find_in(self, 0)
        return a != NO_MATCH
    }

    pub fn <P impl Pattern> contains(const self, const p: P) -> bool {
        var (a, m) = p.find_in(self, 0)
        return a != NO_MATCH
    }

    pub fn <P impl Pattern> starts_with(const self, const p: P) -> bool {
        return self.match_at_(p, 0, self.size()) != NO_MATCH
    }

    pub fn <P impl Pattern> ends_with(const self, const p: P) -> bool {
        return self.match_before_(p, 0, self.size()) != NO_MATCH
    }

    pub fn <P impl Pattern> find(const self, const p: P) -> usize? {
        var (a, m) = p.find_in(self, 0)
        if a == NO_MATCH {
            return null
        }

        return a
    }

    pub fn <P impl Pattern> rfind(const self, const p: P) -> usize? {
        var (a, m) = p.rfind_in(self, self.size())
        if a == NO_MATCH {
            return null
        }

        return a
    }

    /// Matches that do not overlap, counted from the start. An empty pattern
    /// matches before every char and at the end.
    pub fn <P impl Pattern> count(const self, const p: P) -> usize {
        var n            = self.size()
        var from:  usize = 0
        var total: usize = 0
        while from <= n {
            var (a, m) = p.find_in(self, from)
            if a == NO_MATCH {
                break
            }

            total += 1
            from = a + m
            if m == 0 {
                from = self.step_(a)
            }
        }

        return total
    }

    // views, no allocation, no counting
    pub inline fn trim(const self) -> string {
        return self.trim_start().trim_end()
    }

    pub fn trim_start(const self) -> string {
        var        n        = self.size()
        var        i: usize = 0
        var unsafe *q       = self.raw()
        unsafe {
            while i < n {
                var (c, w) = decode_(q + i)
                if !is_space_(c) {
                    break
                }

                i += w
            }
        }

        return self.sub_(i, n)
    }

    pub fn trim_end(const self) -> string {
        var        n  = self.size()
        var unsafe *q = self.raw()
        unsafe {
            while n > 0 {
                var (c, w) = decode_back_(q + n)
                if !is_space_(c) {
                    break
                }

                n -= w
            }
        }

        return self.sub_(0, n)
    }

    /// Without every match of `p` at the start and at the end.
    pub fn <P impl Pattern> trim_matches(const self, const p: P) -> string {
        var lo: usize = 0
        var hi        = self.size()
        while lo < hi {
            var m = self.match_at_(p, lo, hi)
            if m == NO_MATCH || m == 0 {
                break
            }

            lo += m
        }

        while lo < hi {
            var m = self.match_before_(p, lo, hi)
            if m == NO_MATCH || m == 0 {
                break
            }

            hi -= m
        }

        return self.sub_(lo, hi)
    }

    pub fn <P impl Pattern> strip_prefix(const self, const p: P) -> string? {
        var n = self.size()
        var m = self.match_at_(p, 0, n)
        if m == NO_MATCH {
            return null
        }

        return self.sub_(m, n)
    }

    pub fn <P impl Pattern> strip_suffix(const self, const p: P) -> string? {
        var n = self.size()
        var m = self.match_before_(p, 0, n)
        if m == NO_MATCH {
            return null
        }

        return self.sub_(0, n - m)
    }

    pub fn <P impl Pattern> split_once(const self, const p: P) -> (string, string)? {
        var (a, m) = p.find_in(self, 0)
        if a == NO_MATCH {
            return null
        }

        return (self.sub_(0, a), self.sub_(a + m, self.size()))
    }

    pub fn <P impl Pattern> rsplit_once(const self, const p: P) -> (string, string)? {
        var (a, m) = p.rfind_in(self, self.size())
        if a == NO_MATCH {
            return null
        }

        return (self.sub_(0, a), self.sub_(a + m, self.size()))
    }

    /// split / rsplit: the generator BORROWS both `self` and the pattern. In a
    /// `for` header the pattern temporary lives for the loop (language change
    /// 4); a generator stored past its statement (`var it = s.split(sep())`)
    /// dangles, the same class of bug as a stale slice. Until Tether.
    ///
    /// At most `max` pieces: the last one is the rest of the text, matches
    /// and all. An empty pattern splits before every char and at the end.
    pub fn <P impl Pattern> split(const self, const p: P, max: usize = usize::MAX) -> yield string {
        var n            = self.size()
        var start: usize = 0
        var from:  usize = 0
        var left         = max
        if left != 0 {
            while left > 1 && from <= n {
                var (a, m) = p.find_in(self, from)
                if a == NO_MATCH {
                    break
                }

                var at = start
                start = a + m
                from  = start
                if m == 0 {
                    from = self.step_(a)
                }

                left -= 1
                yield self.sub_(at, a)
            }

            yield self.sub_(start, n)
        }
    }

    /// As `split`, from the end: the pieces come last first, and the piece
    /// that keeps unsplit text is the one at the start.
    pub fn <P impl Pattern> rsplit(const self,
                                   const p: P,
                                   max:     usize = usize::MAX) -> yield string {
        var        end  = self.size()
        var        to   = end
        var        left = max
        var        more = true
        var unsafe *q   = self.raw()
        if left != 0 {
            while left > 1 && more {
                var (a, m) = p.rfind_in(self, to)
                if a == NO_MATCH {
                    break
                }

                var stop = end
                end = a
                to  = a
                if m == 0 {
                    if a == 0 {
                        more = false
                    } else {
                        unsafe {
                            var (c, w) = decode_back_(q + a)
                            to = a - w
                        }
                    }
                }

                left -= 1
                yield self.sub_(a + m, stop)
            }

            yield self.sub_(0, end)
        }
    }

    // allocating
    pub fn concat(const self, const o: string) -> string {
        var s = string::with_capacity(self.size() + o.size())
        s.push_str(self)
        s.push_str(o)
        return s
    }

    /// A copy with the first `max` matches of `p` replaced by `by`. An empty
    /// pattern matches before every char and at the end.
    pub fn <P impl Pattern> replace(const self,
                                    const p:  P,
                                    const by: string,
                                    max:      usize = usize::MAX) -> string {
        var n            = self.size()
        var out          = string::with_capacity(n)
        var start: usize = 0
        var from:  usize = 0
        var left         = max
        while left > 0 && from <= n {
            var (a, m) = p.find_in(self, from)
            if a == NO_MATCH {
                break
            }

            out.push_str(self.sub_(start, a))
            out.push_str(by)
            start = a + m
            from  = start
            if m == 0 {
                from = self.step_(a)
            }

            left -= 1
        }

        out.push_str(self.sub_(start, n))
        return out
    }

    pub fn repeat(const self, n: usize) -> string {
        var len          = self.size()
        var total: usize = 0
        @unlikely
        if __builtin_mul_overflow(len, n, &total) || total > MAX_LEN {
            string::too_long()
        }

        // Nothing to repeat, however many times.
        if total == 0 {
            return string()
        }

        var out = string::with_capacity(total)
        for var i: usize = 0; i < n; i++ {
            out.push_str(self)
        }

        return out
    }

    pub fn to_ascii_upper(const self) -> string {
        var out = self.to_owned()
        var n   = out.size()
        if n != 0 {
            unsafe {
                var unsafe *q = out.raw_mut()
                for var i: usize = 0; i < n; i++ {
                    var b = q[i]
                    // 'a'..'z'; a byte of a longer sequence is 0x80 or more.
                    if b >= 97 && b <= 122 {
                        q[i] = b - 32
                    }
                }
            }
        }

        return out
    }

    pub fn to_ascii_lower(const self) -> string {
        var out = self.to_owned()
        var n   = out.size()
        if n != 0 {
            unsafe {
                var unsafe *q = out.raw_mut()
                for var i: usize = 0; i < n; i++ {
                    var b = q[i]
                    if b >= 65 && b <= 90 {
                        q[i] = b + 32
                    }
                }
            }
        }

        return out
    }

    /// `width` counts codepoints. A string already that long is copied as it is.
    pub fn pad_start(const self, width: usize, fill: char = ' ') -> string {
        var cps = self.codepoints()
        if cps >= width {
            return self.to_owned()
        }

        var out = string(fill, width - cps)
        out.push_str(self)
        return out
    }

    pub fn pad_end(const self, width: usize, fill: char = ' ') -> string {
        var cps = self.codepoints()
        if cps >= width {
            return self.to_owned()
        }

        var out = string::with_capacity(
            self.size() + (width - cps) * encoded_len_(fill),
        )

        out.push_str(self)
        for var i = cps; i < width; i++ {
            out.push(fill)
        }

        return out
    }

    // mutation, byte offsets; view and literal become heap first
    @hot_path pub inline fn push(self, c: char) {
        var m      = self.meta
        var v: u32 = c
        @likely
        if (m & OWN_BIT) != 0 && v < 0x80 {
            var len = m >> LEN_SHIFT
            unsafe {
                @likely
                if len < *self.hdr_cap() {
                    // The byte and the NUL after it, as one two-byte store.
                    var pair: u16 = v as u16
                    eval if defined!(__BIG_ENDIAN__) {
                        pair = pair << 8
                    }

                    __builtin_copy(
                        self.raw_mut() + len,
                        &pair as unsafe *const u8,
                        2,
                    )

                    self.meta = m + (1 << LEN_SHIFT)
                    return
                }
            }
        }

        var (np, nm) = string::push_slow_(self.raw(), m, c)
        unsafe {
            self.p.rw = np as unsafe *u8 as *u8
        }

        self.meta = nm
    }

    @hot_path pub inline fn push_str(self, const s: string) { // counts s while copying it if s is a non-ASCII view
        var om = s.meta
        var m  = self.meta
        var n  = om >> LEN_SHIFT
        // Owned, and `s` known to be ASCII: the count word and both state
        // bits stay as they are.
        @likely
        if ((m & OWN_BIT) | (om & ASCII_BIT)) == (OWN_BIT | ASCII_BIT) {
            var len = m >> LEN_SHIFT
            var nl  = len + n
            unsafe {
                @likely
                if nl <= *self.hdr_cap() {
                    // The NUL and the length go first: nothing is live
                    // after the copy, so where its length is not a
                    // constant the copy is a tail call and this path saves
                    // no register. The bytes of `s` end at or before the
                    // old length, so neither store touches them.
                    var unsafe *q = self.raw_mut()
                    q[nl]     = 0
                    self.meta = m + (n << LEN_SHIFT)
                    __builtin_copy(q + len, s.raw(), n)
                    return
                }
            }
        }

        var (np, nm) = string::append_slow_(self.raw(), m, s.raw(), om)
        unsafe {
            self.p.rw = np as unsafe *u8 as *u8
        }

        self.meta = nm
    }

    pub inline fn <A impl Append> append(self, const v: A) { // formats v onto the end
        v.append_to(&self)
    }

    /// Inserts `s` before byte `at`, which is a char boundary at or below `size()`.
    pub fn insert(self, at: usize, const s: string) {
        var m   = self.meta
        var len = m >> LEN_SHIFT
        @unlikely
        if !self.is_char_boundary(at) {
            self.boundary_fail(at)
        }

        var n = s.size()
        if n == 0 {
            return
        }

        // `s` inside this string: the shift below would move its bytes.
        @unlikely
        if self.offset_in_(s.raw()) != NO_MATCH {
            var tmp = s.to_owned()
            self.insert(at, tmp)
            return
        }

        var nl   = len + n
        var fits = false
        if (m & OWN_BIT) != 0 {
            unsafe {
                fits = nl <= *self.hdr_cap()
            }
        }

        if !fits {
            self.grow(nl)
        }

        var conts = s.conts_()
        unsafe {
            var unsafe *q = self.raw_mut()
            __builtin_move_mem(q + at + n, q + at, len - at + 1)
            __builtin_copy(q + at, s.raw(), n)
            if conts != 0 {
                *self.hdr_conts() += conts
            }
        }

        self.meta = (nl << LEN_SHIFT) | (if conts == 0 => (self.meta & ASCII_BIT)
                                         else => 0) | ST_HEAP
    }

    /// Removes bytes [r.begin, r.end), both char boundaries.
    pub fn remove_range(self, r: Range<usize>) {
        var m   = self.meta
        var len = m >> LEN_SHIFT
        var lo  = r.begin
        var hi  = r.end
        if r.inclusive {
            @unlikely
            if hi == usize::MAX {
                range_fail(lo, hi, len)
            }

            hi += 1
        }

        @unlikely
        if lo > hi || hi > len {
            range_fail(lo, hi, len)
        }

        @unlikely
        if !self.is_char_boundary(lo) {
            self.boundary_fail(lo)
        }

        @unlikely
        if !self.is_char_boundary(hi) {
            self.boundary_fail(hi)
        }

        if lo == hi {
            return
        }

        if (m & OWN_BIT) == 0 {
            self.make_owned()
        }

        unsafe {
            var unsafe *q          = self.raw_mut()
            var        gone: usize = 0
            if (m & ASCII_BIT) == 0 {
                gone = count_conts_(q + lo, hi - lo)
            }

            __builtin_move_mem(q + lo, q + hi, len - hi + 1)
            self.set_len_(len - (hi - lo), *self.hdr_conts() - gone)
        }
    }

    /// Length and count after a removal. Heap only. Text left without a
    /// continuation byte is ASCII, and the bit says so again.
    priv inline fn set_len_(self, len: usize, conts: usize) {
        unsafe {
            *self.hdr_conts() = conts
        }

        self.meta = (len << LEN_SHIFT) | (if conts == 0 => ASCII_BIT else => 0) | ST_HEAP
    }

    pub fn pop(self) -> char? {
        var m   = self.meta
        var len = m >> LEN_SHIFT
        if len == 0 {
            return null
        }

        if (m & OWN_BIT) == 0 {
            self.make_owned()
        }

        unsafe {
            var unsafe *q = self.raw_mut()
            var (c, w)    = decode_back_(q + len)
            q[len - w] = 0
            self.set_len_(len - w, *self.hdr_conts() - (w - 1))
            return c
        }
    }

    /// Keeps the first `bytes` bytes; a length at or past `size()` changes nothing.
    pub fn truncate(self, bytes: usize) {
        var m   = self.meta
        var len = m >> LEN_SHIFT
        if bytes >= len {
            return
        }

        @unlikely
        if !self.is_char_boundary(bytes) {
            self.boundary_fail(bytes)
        }

        if (m & OWN_BIT) == 0 {
            // Nothing is kept, so nothing is copied and no block is made.
            if bytes == 0 {
                self.set_empty_()
                return
            }

            // Shorten the borrowed text first, so only what is kept is copied.
            self.meta = (bytes << LEN_SHIFT) | (m & ASCII_BIT) | ST_VIEW
            self.make_owned()
            return
        }

        unsafe {
            var unsafe *q           = self.raw_mut()
            var        conts: usize = 0
            if (m & ASCII_BIT) == 0 {
                // Count whichever side is shorter.
                if len - bytes <= bytes {
                    conts = *self.hdr_conts() - count_conts_(
                        q + bytes,
                        len - bytes,
                    )
                } else {
                    conts = count_conts_(q, bytes)
                }
            }

            q[bytes] = 0
            self.set_len_(bytes, conts)
        }
    }

    /// Empties the string and keeps an owned buffer.
    pub inline fn clear(self) {
        if (self.meta & OWN_BIT) != 0 {
            unsafe {
                self.raw_mut()[0] = 0
            }

            self.set_len_(0, 0)
            return
        }

        self.set_empty_()
    }

    // compare, parse
    @pure pub fn eq_ignore_ascii_case(const self, const o: string) -> bool {
        var n = self.size()
        if n != o.size() {
            return false
        }

        var unsafe *a = self.raw()
        var unsafe *b = o.raw()
        unsafe {
            for var i: usize = 0; i < n; i++ {
                var x = a[i]
                var y = b[i]
                if x >= 65 && x <= 90 {
                    x += 32
                }

                if y >= 65 && y <= 90 {
                    y += 32
                }

                if x != y {
                    return false
                }
            }
        }

        return true
    }

    pub fn <T impl FromStr> parse(const self) panic(ParseError) -> T {
        var err = ParseError { at: 0, kind: ParseErrorKind::None }

        var r? = T::from_str(self, &err)
        if r? {
            return r
        }

        panic err
    }
}

/// Borrows the string it came from. Move-only.
pub class Chars {
    priv var ptr:   *const u8?
    priv var front: usize
    priv var back:  usize

    /// Over the `n` bytes of valid UTF-8 at `p`.
    prot inline fn Chars(self, p: *const u8, n: usize) {
        self.ptr   = p
        self.front = 0
        self.back  = n
    }

    @move pub inline fn Chars(self, other: Self) {
        self.ptr    = other.ptr
        self.front  = other.front
        self.back   = other.back
        other.front = other.back
    }

    /// The first byte of the borrowed text; `ptr` is never null.
    @pure prot inline fn base_(const self) -> unsafe *const u8 {
        if self.ptr? {
            unsafe {
                return self.ptr as unsafe *const u8
            }
        }

        unsafe {
            __builtin_unreachable()
        }
    }
}

extend Chars impl DoubleEnded {
    type Item = char
    @hot_path inline fn next(self) -> char? {
        if self.front == self.back {
            return null
        }

        unsafe {
            var (c, w) = decode_(self.base_() + self.front)
            self.front += w
            return c
        }
    }

    @hot_path inline fn next_back(self) -> char? {
        if self.front == self.back {
            return null
        }

        unsafe {
            var (c, w) = decode_back_(self.base_() + self.back)
            self.back -= w
            return c
        }
    }
}
