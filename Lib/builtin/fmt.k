/// --- The Kairo Project ---------------------------- Lib/builtin/fmt.k --- ///
///
///   The f-string builder. FStringLowering compiles an f-string into
///   straight-line calls on one FmtBuf: a capacity computed at compile
///   time, one `text` per run of literal bytes, one `put_*` per hole, one
///   `finish`. Nothing is parsed at run time and nothing is dispatched: the
///   hole's type chose its method at compile time, and its spec arrives as
///   one packed u64, 0 for "defaults".
///
///   The spec word, low bit first (AST/LangItems.k packs it):
///     bits  0..15  width          0 = none
///     bits 16..31  precision + 1  0 = none
///     bits 32..52  fill codepoint 0 = ' '
///     bits 53..54  align          0 = the kind's default, 1 <, 2 >, 3 ^
///     bits 55..56  base           0 = 10, 1 = 16 (or 'e' on a float), 2 = 8, 3 = 2
///     bits 57..61  flags          1 '+', 2 '#', 4 '0', 8 upper, 16 '?'
///
///   Every writer counts what it writes: a formatter emits ASCII and adds
///   its byte count to cp_len, `text` is told its count, `put_str` copies
///   the source's. No producer scans.
///
///   Written to the C++ core EmitIR emits today (if-chains, indexed for,
///   loop); nothing here needs more than that.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "../rt/fmt.h"

import string::*

pub class FmtBuf {
    pub var data:   *u8
    pub var len:    usize
    pub var cp_len: usize
    pub var cap:    usize

    /// `cap` bytes of headroom, plus the NUL finish() writes.
    pub fn FmtBuf(self, cap: usize) {
        self.data   = kairo_rt_fmt_alloc(cap + 1)
        self.len    = 0
        self.cp_len = 0
        self.cap    = cap
    }

    // --- the API the lowering calls -----------------------------------------

    /// Literal bytes: `n` of them, encoding `cp` codepoints. Both are
    /// constants at every call site.
    pub inline fn text(self, p: *const u8, n: usize, cp: usize) {
        self.reserve_(n)
        for var i: usize = 0; i < n; ++i { self.data[self.len + i] = p[i] }
        self.len    += n
        self.cp_len += cp
    }

    pub inline fn put_str(self, const s: string, spec: u64) {
        if spec == 0 { self.text(s.data, s.len, s.cp_len); return }
        var take_cp = s.cp_len
        var take_n  = s.len
        var prec    = FmtBuf::prec_(spec)
        if (prec >= 0) && ((prec as usize) < s.cp_len) {
            take_cp = prec as usize
            take_n  = FmtBuf::byte_offset_(s.data, s.len, take_cp)
        }
        if (FmtBuf::flags_(spec) & 16) != 0 { self.quoted_(s.data, take_n, take_cp, spec); return }
        var width = FmtBuf::width_(spec)
        var pad: usize = if width > take_cp { width - take_cp } else { 0 }
        var right = self.pad_open_(pad, spec, 1)
        self.text(s.data, take_n, take_cp)
        self.pad_(right, FmtBuf::fill_(spec))
    }

    pub inline fn put_bool(self, v: bool, spec: u64) {
        var t = "true"
        var f = "false"
        if v { self.ascii_(t.data, 4, spec, 1) } else { self.ascii_(f.data, 5, spec, 1) }
    }

    pub fn put_char(self, c: char, spec: u64) {
        var tmp: [u8; 4]
        var n = FmtBuf::encode_(c as u32, &tmp[0])
        if (FmtBuf::flags_(spec) & 16) != 0 {
            self.reserve_(n + 4)
            self.byte_(39)                                    // '
            self.escaped_(&tmp[0], n, 39)
            self.byte_(39)
            return
        }
        var width = FmtBuf::width_(spec)
        var pad: usize = if width > 1 { width - 1 } else { 0 }
        var right = self.pad_open_(pad, spec, 1)
        self.text(&tmp[0], n, 1)
        self.pad_(right, FmtBuf::fill_(spec))
    }

    /// Storage, not a number: two hex digits, `#` adds `0x`.
    pub fn put_byte(self, b: byte, spec: u64) {
        var v = b as u8
        var tmp: [u8; 2]
        tmp[0] = FmtBuf::digit_(v >> 4, false)
        tmp[1] = FmtBuf::digit_(v & 15, false)
        var one: u64 = 1                            // typed here: `1 << 55` alone is an i32
        var hex = one << 55                         // base field = 1 (hex)
        self.number_(&tmp[0], 2, false, spec | hex)
    }

    pub inline fn put_i8(self,    v: i8,    spec: u64) { self.int64_(v as u64, v < 0, spec) }
    pub inline fn put_i16(self,   v: i16,   spec: u64) { self.int64_(v as u64, v < 0, spec) }
    pub inline fn put_i32(self,   v: i32,   spec: u64) { self.int64_(v as u64, v < 0, spec) }
    pub inline fn put_i64(self,   v: i64,   spec: u64) { self.int64_(v as u64, v < 0, spec) }
    pub inline fn put_isize(self, v: isize, spec: u64) { self.int64_(v as u64, v < 0, spec) }
    pub inline fn put_u8(self,    v: u8,    spec: u64) { self.int64_(v, false, spec) }
    pub inline fn put_u16(self,   v: u16,   spec: u64) { self.int64_(v, false, spec) }
    pub inline fn put_u32(self,   v: u32,   spec: u64) { self.int64_(v, false, spec) }
    pub inline fn put_u64(self,   v: u64,   spec: u64) { self.int64_(v, false, spec) }
    pub inline fn put_usize(self, v: usize, spec: u64) { self.int64_(v as u64, false, spec) }
    pub inline fn put_i128(self,  v: i128,  spec: u64) { self.int128_(v as u128, v < 0, spec) }
    pub inline fn put_u128(self,  v: u128,  spec: u64) { self.int128_(v, false, spec) }
    pub inline fn put_i256(self,  v: i256,  spec: u64) { self.int512_(v as u512, v < 0, spec) }
    pub inline fn put_u256(self,  v: u256,  spec: u64) { self.int512_(v as u512, false, spec) }
    pub inline fn put_i512(self,  v: i512,  spec: u64) { self.int512_(v as u512, v < 0, spec) }
    pub inline fn put_u512(self,  v: u512,  spec: u64) { self.int512_(v, false, spec) }

    pub inline fn put_f16(self,    v: f16,    spec: u64) { self.float_(v as f80, spec) }
    pub inline fn put_bf16(self,   v: bf16,   spec: u64) { self.float_(v as f80, spec) }
    pub inline fn put_f32(self,    v: f32,    spec: u64) { self.float_(v as f80, spec) }
    pub inline fn put_f64(self,    v: f64,    spec: u64) { self.float_(v as f80, spec) }
    pub inline fn put_f80(self,    v: f80,    spec: u64) { self.float_(v, spec) }
    pub inline fn put_f128(self,   v: f128,   spec: u64) { self.float_(v as f80, spec) }   // TODO(rt): lossy past 64 mantissa bits
    // TODO(rt): the corelib floats have no C++ definition yet (::kairo::rt::*); restore these with it.
    // pub inline fn put_f8e4m3(self, v: f8e4m3, spec: u64) { self.float_((v as f32) as f80, spec) }
    // pub inline fn put_f8e5m2(self, v: f8e5m2, spec: u64) { self.float_((v as f32) as f80, spec) }
    // pub inline fn put_f256(self,   v: f256,   spec: u64) { self.float_((v as f64) as f80, spec) }   // TODO(rt): lossy; needs the corelib printer
    // pub inline fn put_f512(self,   v: f512,   spec: u64) { self.float_((v as f64) as f80, spec) }   // TODO(rt): same

    /// `<name> @ 0x<hex>`, or `&null`. `name` is the pointee's spelling, a
    /// constant at the call site.
    pub fn put_ptr(self, addr: usize, name: *const u8, name_len: usize, spec: u64) {
        if addr == 0 {
            var s = "&null"
            self.text(s.data, s.len, s.cp_len)
            return
        }
        self.text(name, name_len, FmtBuf::cp_count_(name, name_len))
        var at = " @ 0x"
        self.text(at.data, at.len, at.cp_len)
        var one: u64 = 1
        var hex = one << 55
        self.int64_(addr as u64, false, hex)
    }

    /// Hands the buffer over. The result owns it: cap > 0.
    pub inline fn finish(self) -> string {
        self.data[self.len] = 0
        var s = string()
        s.data   = self.data as const *u8
        s.len    = self.len
        s.cp_len = self.cp_len
        s.cap    = self.cap + 1
        self.data = &null
        self.len  = 0
        self.cap  = 0
        return s
    }

    // --- capacity ----------------------------------------------------------------

    priv inline fn reserve_(self, n: usize) {
        if self.len + n > self.cap { self.grow_(self.len + n) }
    }

    priv fn grow_(self, need: usize) {
        var nc = self.cap * 2
        if nc < need { nc = need }
        self.data = kairo_rt_fmt_realloc(self.data, nc + 1)
        self.cap  = nc
    }

    /// One ASCII byte, headroom already reserved.
    priv inline fn byte_(self, b: u8) {
        self.data[self.len] = b
        self.len    += 1
        self.cp_len += 1
    }

    /// One codepoint, UTF-8 encoded, headroom already reserved.
    priv fn cp_(self, cp: u32) {
        var tmp: [u8; 4]
        var n = FmtBuf::encode_(cp, &tmp[0])
        for var i: usize = 0; i < n; ++i { self.data[self.len + i] = tmp[i] }
        self.len    += n
        self.cp_len += 1
    }

    // --- the spec word --------------------------------------------------------------

    priv static fn width_(spec: u64) -> usize { return (spec & 0xFFFF) as usize }
    priv static fn prec_(spec: u64)  -> isize { return (((spec >> 16) & 0xFFFF) as isize) - 1 }
    priv static fn fill_(spec: u64)  -> u32   { var f = ((spec >> 32) & 0x1FFFFF) as u32; return if f != 0 { f } else { 32 } }
    priv static fn align_(spec: u64) -> u64   { return (spec >> 53) & 3 }
    priv static fn base_(spec: u64)  -> u64   { return (spec >> 55) & 3 }
    priv static fn flags_(spec: u64) -> u64   { return (spec >> 57) & 31 }

    // --- padding ------------------------------------------------------------------------

    /// Writes the left padding for `pad` fill codepoints under the spec's
    /// alignment (\p dflt when unset: 1 left for text, 2 right for numbers)
    /// and returns how many go on the right.
    priv fn pad_open_(self, pad: usize, spec: u64, dflt: u64) -> usize {
        if pad == 0 { return 0 }
        var align = FmtBuf::align_(spec)
        if align == 0 { align = dflt }
        var left: usize = 0
        if align == 2 { left = pad } else if align == 3 { left = pad / 2 }
        self.pad_(left, FmtBuf::fill_(spec))
        return pad - left
    }

    priv fn pad_(self, n: usize, fill: u32) {
        if n == 0 { return }
        if fill < 128 {
            self.reserve_(n)
            for var i: usize = 0; i < n; ++i { self.byte_(fill as u8) }
            return
        }
        self.reserve_(n * 4)
        for var i: usize = 0; i < n; ++i { self.cp_(fill) }
    }

    /// ASCII text of a known length with width and alignment applied.
    priv fn ascii_(self, p: *const u8, n: usize, spec: u64, dflt: u64) {
        var width = FmtBuf::width_(spec)
        var pad: usize = if width > n { width - n } else { 0 }
        var right = self.pad_open_(pad, spec, dflt)
        self.text(p, n, n)
        self.pad_(right, FmtBuf::fill_(spec))
    }

    // --- numbers ----------------------------------------------------------------------

    priv static fn digit_(d: u8, upper: bool) -> u8 {
        if d < 10 { return 48 + d }
        return (if upper { 55 } else { 87 }) + d          // 'A' - 10 / 'a' - 10
    }

    /// Sign, `0x`/`0o`/`0b`, zero-padding after them, fill-padding around
    /// them: the one place every number's spec is applied. \p p holds the
    /// digits only.
    priv fn number_(self, p: *const u8, n: usize, neg: bool, spec: u64) {
        var flags = FmtBuf::flags_(spec)
        var base  = FmtBuf::base_(spec)
        var sign: u8 = 0
        if neg { sign = 45 } else if (flags & 1) != 0 { sign = 43 }          // '-' '+'
        var pfx: usize = if (flags & 2) != 0 { if base != 0 { 2 } else { 0 } } else { 0 }
        var body  = n + pfx + (if sign != 0 { 1 } else { 0 })
        var width = FmtBuf::width_(spec)
        var pad: usize = if width > body { width - body } else { 0 }
        var right: usize = 0

        if (flags & 4) != 0 {
            self.reserve_(body + pad)
            if sign != 0 { self.byte_(sign) }
            if pfx != 0 { self.prefix_(base, flags) }
            for var k: usize = 0; k < pad; ++k { self.byte_(48) }
        } else {
            right = self.pad_open_(pad, spec, 2)
            self.reserve_(body)
            if sign != 0 { self.byte_(sign) }
            if pfx != 0 { self.prefix_(base, flags) }
        }
        for var k: usize = 0; k < n; ++k { self.byte_(p[k]) }
        self.pad_(right, FmtBuf::fill_(spec))
    }

    priv fn prefix_(self, base: u64, flags: u64) {
        self.byte_(48)
        // Bound first: an argument is typed before the parameter is known, so
        // the literals in an inline `if` would settle as i32.
        var x: u8 = if (flags & 8) != 0 { 88 } else { 120 }                    // X x
        if base == 1      { self.byte_(x) }
        else if base == 2 { self.byte_(111) }                                     // o
        else              { self.byte_(98)  }                                     // b
    }

    priv fn int64_(self, v: u64, neg: bool, spec: u64) {
        var mag = v
        if neg { mag = 0 - mag }
        var tmp: [u8; 72]
        var i: usize = 72
        var base  = FmtBuf::base_(spec)
        var upper = (FmtBuf::flags_(spec) & 8) != 0
        if base == 0 {
            while mag >= 10 {
                var q = mag / 10
                i -= 1
                tmp[i] = (48 + (mag - q * 10)) as u8
                mag = q
            }
            i -= 1
            tmp[i] = (48 + mag) as u8
        } else {
            var shift: u64 = 4
            var mask:  u64 = 15
            if base == 2 { shift = 3; mask = 7 } else if base == 3 { shift = 1; mask = 1 }
            loop {
                i -= 1
                tmp[i] = FmtBuf::digit_((mag & mask) as u8, upper)
                mag = mag >> shift
                if mag == 0 { break }
            }
        }
        self.number_(&tmp[i], 72 - i, neg, spec)
    }

    priv fn int128_(self, v: u128, neg: bool, spec: u64) {
        var mag = v
        if neg { mag = 0 - mag }
        var tmp: [u8; 136]
        var i: usize = 136
        var base  = FmtBuf::base_(spec)
        var upper = (FmtBuf::flags_(spec) & 8) != 0
        if base == 0 {
            while mag >= 10 {
                var q = mag / 10
                i -= 1
                tmp[i] = (48 + ((mag - q * 10) as u64)) as u8
                mag = q
            }
            i -= 1
            tmp[i] = (48 + (mag as u64)) as u8
        } else {
            var shift: u32 = 4
            var mask: u128 = 15
            if base == 2 { shift = 3; mask = 7 } else if base == 3 { shift = 1; mask = 1 }
            loop {
                i -= 1
                tmp[i] = FmtBuf::digit_((mag & mask) as u8, upper)
                mag = mag >> shift
                if mag == 0 { break }
            }
        }
        self.number_(&tmp[i], 136 - i, neg, spec)
    }

    /// i256 through u512. Division on _BitInt(512) is a library call; this
    /// path is rare and correct, not fast.
    priv fn int512_(self, v: u512, neg: bool, spec: u64) {
        var mag = v
        if neg { mag = 0 - mag }
        var tmp: [u8; 520]
        var i: usize = 520
        var base  = FmtBuf::base_(spec)
        var upper = (FmtBuf::flags_(spec) & 8) != 0
        if base == 0 {
            while mag >= 10 {
                var q = mag / 10
                i -= 1
                tmp[i] = (48 + ((mag - q * 10) as u64)) as u8
                mag = q
            }
            i -= 1
            tmp[i] = (48 + (mag as u64)) as u8
        } else {
            var shift: u32 = 4
            var mask: u512 = 15
            if base == 2 { shift = 3; mask = 7 } else if base == 3 { shift = 1; mask = 1 }
            loop {
                i -= 1
                tmp[i] = FmtBuf::digit_((mag & mask) as u8, upper)
                mag = mag >> shift
                if mag == 0 { break }
            }
        }
        self.number_(&tmp[i], 520 - i, neg, spec)
    }

    /// The runtime prints the magnitude; the sign and padding are number_'s,
    /// so `{v:08.3}` and `{v:+}` behave as they do for integers.
    priv fn float_(self, v: f80, spec: u64) {
        var neg = v < 0.0
        var mag = v
        if neg { mag = 0.0 - v }
        var conv: u8 = 103                                                      // g
        if FmtBuf::base_(spec) == 1 { conv = if (FmtBuf::flags_(spec) & 8) != 0 { 69 } else { 101 } }   // E e
        var tmp: [u8; 64]
        var n = kairo_rt_fmt_f80(&tmp[0], 64, mag, FmtBuf::prec_(spec) as i32, conv)
        self.number_(&tmp[0], n as usize, neg, spec)
    }

    // --- text ------------------------------------------------------------------------------

    /// `"..."` with `"`, `\` and controls escaped. Width pads the quoted form.
    priv fn quoted_(self, p: *const u8, n: usize, cp: usize, spec: u64) {
        self.reserve_(n * 4 + 2)
        self.byte_(34)
        self.escaped_(p, n, 34)
        self.byte_(34)
    }

    priv fn escaped_(self, p: *const u8, n: usize, quote: u8) {
        for var i: usize = 0; i < n; ++i {
            var b = p[i]
            if (b == quote) || (b == 92) { self.byte_(92); self.byte_(b); continue }
            if b == 10 { self.byte_(92); self.byte_(110); continue }              // \n
            if b == 9  { self.byte_(92); self.byte_(116); continue }              // \t
            if b == 13 { self.byte_(92); self.byte_(114); continue }              // \r
            if b < 32 {
                self.byte_(92); self.byte_(120)                                   // \x
                self.byte_(FmtBuf::digit_(b >> 4, false))
                self.byte_(FmtBuf::digit_(b & 15, false))
                continue
            }
            self.data[self.len] = b
            self.len += 1
            if (b & 0xC0) != 0x80 { self.cp_len += 1 }
        }
    }

    priv static fn cp_count_(p: *const u8, n: usize) -> usize {
        var cp: usize = 0
        for var i: usize = 0; i < n; ++i { if (p[i] & 0xC0) != 0x80 { cp += 1 } }
        return cp
    }

    /// Byte offset of codepoint \p cps in \p p, or \p n.
    priv static fn byte_offset_(p: *const u8, n: usize, cps: usize) -> usize {
        var seen: usize = 0
        for var i: usize = 0; i < n; ++i {
            if (p[i] & 0xC0) != 0x80 {
                if seen == cps { return i }
                seen += 1
            }
        }
        return n
    }

    priv static fn encode_(cp: u32, dst: *u8) -> usize {
        if cp < 0x80    { dst[0] = cp as u8; return 1 }
        if cp < 0x800   { dst[0] = (0xC0 | (cp >> 6)) as u8; dst[1] = (0x80 | (cp & 0x3F)) as u8; return 2 }
        if cp < 0x10000 {
            dst[0] = (0xE0 | (cp >> 12)) as u8
            dst[1] = (0x80 | ((cp >> 6) & 0x3F)) as u8
            dst[2] = (0x80 | (cp & 0x3F)) as u8
            return 3
        }
        dst[0] = (0xF0 | (cp >> 18)) as u8
        dst[1] = (0x80 | ((cp >> 12) & 0x3F)) as u8
        dst[2] = (0x80 | ((cp >> 6) & 0x3F)) as u8
        dst[3] = (0x80 | (cp & 0x3F)) as u8
        return 4
    }
}