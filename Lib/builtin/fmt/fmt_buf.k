/// --- The Kairo Project -------------------- Lib/builtin/fmt/fmt_buf.k --- ///
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

ffi "c++" import "rt/fmt.h"

import string::*
import alloc_raw::{alloc_raw, free_raw, resize_raw, oom}
import base::intrinsics::{ __builtin_copy }

/// "00" "01" ... "99": the two ASCII digits of every value below 100.
static DIGIT_PAIRS: [u8; 200] = [48, 48, 48, 49, 48, 50, 48, 51, 48, 52, 48, 53, 48, 54, 48, 55, 48, 56, 48, 57, 49, 48, 49, 49, 49, 50, 49, 51, 49, 52, 49, 53, 49, 54, 49, 55, 49, 56, 49, 57, 50, 48, 50, 49, 50, 50, 50, 51, 50, 52, 50, 53, 50, 54, 50, 55, 50, 56, 50, 57, 51, 48, 51, 49, 51, 50, 51, 51, 51, 52, 51, 53, 51, 54, 51, 55, 51, 56, 51, 57, 52, 48, 52, 49, 52, 50, 52, 51, 52, 52, 52, 53, 52, 54, 52, 55, 52, 56, 52, 57, 53, 48, 53, 49, 53, 50, 53, 51, 53, 52, 53, 53, 53, 54, 53, 55, 53, 56, 53, 57, 54, 48, 54, 49, 54, 50, 54, 51, 54, 52, 54, 53, 54, 54, 54, 55, 54, 56, 54, 57, 55, 48, 55, 49, 55, 50, 55, 51, 55, 52, 55, 53, 55, 54, 55, 55, 55, 56, 55, 57, 56, 48, 56, 49, 56, 50, 56, 51, 56, 52, 56, 53, 56, 54, 56, 55, 56, 56, 56, 57, 57, 48, 57, 49, 57, 50, 57, 51, 57, 52, 57, 53, 57, 54, 57, 55, 57, 56, 57, 57]

/// Bytes FmtBuf holds in itself before it spills to the heap, NUL included.
eval FMTBUF_INLINE: usize = 128

pub class FmtBuf {
    pub var data:   *u8          // inline_ until the first spill, then the heap
    pub var len:    usize
    pub var cp_len: usize
    pub var cap:    usize        // usable bytes; data has cap + 1 (the NUL)
    var inline_:    [u8; 128]

    /// A bound of `cap` bytes. Up to FMTBUF_INLINE - 1 the buffer is inline_
    /// and the heap is never touched unless the text outgrows it; past that
    /// the heap block is taken now, sized once.
    pub fn FmtBuf(self, cap: usize) {
        self.len    = 0
        self.cp_len = 0
        if cap < FMTBUF_INLINE {
            self.data = &self.inline_[0]
            self.cap  = FMTBUF_INLINE - 1
        } else {
            // The allocator in effect, as string's own blocks: finish() hands
            // this block to a string, whose destructor frees it with free_raw.
            var unsafe *p = alloc_raw(cap + 1, 1)
            @unlikely if p == &null { oom(cap + 1, 1) }
            unsafe { self.data = p as *u8 }
            self.cap = cap
        }
    }

    /// An empty buffer on its inline storage: what a user declares to format
    /// into repeatedly (`var b = FmtBuf()`, then `b.write(f"...")`).
    pub fn FmtBuf(self) {
        self.len    = 0
        self.cp_len = 0
        self.data   = &self.inline_[0]
        self.cap    = FMTBUF_INLINE - 1
    }

    /// Room for `n` more bytes, so the puts that follow never grow.
    pub inline fn reserve(self, n: usize) { self.reserve_(n) }

    /// Appends a string as `{s}` would. `b.write(f"...")` never reaches this:
    /// the lowering writes the f-string's parts straight onto `b`.
    pub inline fn write(self, const s: string) { self.text(s.as_ptr(), s.length(), s.codepoints()) }

    /// data points into the object itself: never copied, never moved. Every
    /// FmtBuf is a statement-local of the lowering or a user local.
    @copy fn FmtBuf(self, const other: Self) = delete
    @move fn FmtBuf(self, other: Self) = delete

    /// A spilled buffer that was never handed over by finish().
    fn op delete(self) {
        if self.spilled_() { unsafe { free_raw(self.data as unsafe *u8, self.cap + 1, 1) } }
    }

    priv inline fn spilled_(const self) -> bool {
        return (self.data != &null) && (self.data != &self.inline_[0])
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
        if spec == 0 {
            self.text(s.as_ptr(), s.length(), s.codepoints())
            return
        }

        var take_cp = s.codepoints()
        var take_n  = s.length()
        var prec    = FmtBuf::prec_(spec)

        if (prec >= 0) && ((prec as usize) < s.codepoints()) {
            take_cp = prec as usize
            take_n  = FmtBuf::byte_offset_(s.as_ptr(), s.length(), take_cp)
        }

        if (FmtBuf::flags_(spec) & 16) != 0 {
            self.quoted_(s.as_ptr(), take_n, take_cp, spec)
            return
        }

        var width = FmtBuf::width_(spec)
        var pad: usize = if width > take_cp => width - take_cp else => 0
        var right = self.pad_open_(pad, spec, 1)

        self.text(s.as_ptr(), take_n, take_cp)
        self.pad_(right, FmtBuf::fill_(spec))
    }

    pub inline fn put_bool(self, v: bool, spec: u64) {
        var t = "true"
        var f = "false"
        if v { self.ascii_(t.as_ptr(), 4, spec, 1) } else { self.ascii_(f.as_ptr(), 5, spec, 1) }
    }

    pub fn put_char(self, c: char, spec: u64) {
        var tmp: [u8; 4]
        var n = FmtBuf::encode_(c, &tmp[0])
        if (FmtBuf::flags_(spec) & 16) != 0 {
            self.reserve_(n * 4 + 2)
            self.byte_(39)                                    // '
            self.escaped_(&tmp[0], n, 39)
            self.byte_(39)
            return
        }
        var width = FmtBuf::width_(spec)
        var pad: usize = if width > 1 => width - 1 else => 0
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

    // --- floats --------------------------------------------------------------------
    //
    // One runtime entry per format, never a widened f80: shortest digits are
    // a property of the SOURCE format (rt/fmt.h says why). The sign is read
    // from the value's bytes -- rt/fmt.h prints |v| and ignores it, and
    // `v < 0.0` loses -0.0 and a signed NaN -- through an unsafe *const u8,
    // the one aliasing C++ permits for every type; clang folds the byte
    // loads into one. Little-endian byte order; every target Kairo has.
    //
    // The digits are written INTO the buffer, above everything the padded
    // result can reach, and number_ moves them down: no stack buffer, no
    // precision cap, and no reallocation between the write and the move,
    // because float_open_ reserves both and every reserve_ under it is a
    // compare that fails.

    pub inline fn put_f16(self, v: f16, spec: u64) {
        var bits: u16 = 0
        unsafe { bits = FmtBuf::bits16_((&v) as unsafe *const u8, 0) }
        var slot = self.float_open_(spec)
        var n: i32 = 0
        unsafe { n = kairo_rt_fmt_f16(unsafe &self.data[slot], FmtBuf::float_cap_(spec), bits, FmtBuf::prec_(spec) as i32, FmtBuf::conv_(spec)) }
        self.number_(&self.data[slot], n as usize, (bits >> 15) != 0, spec)
    }

    pub inline fn put_bf16(self, v: bf16, spec: u64) {
        var bits: u16 = 0
        unsafe { bits = FmtBuf::bits16_((&v) as unsafe *const u8, 0) }
        var slot = self.float_open_(spec)
        var n: i32 = 0
        unsafe { n = kairo_rt_fmt_bf16(unsafe &self.data[slot], FmtBuf::float_cap_(spec), bits, FmtBuf::prec_(spec) as i32, FmtBuf::conv_(spec)) }
        self.number_(&self.data[slot], n as usize, (bits >> 15) != 0, spec)
    }

    pub inline fn put_f32(self, v: f32, spec: u64) {
        var neg = false
        unsafe { neg = (FmtBuf::bits32_((&v) as unsafe *const u8, 0) >> 31) != 0 }
        if spec == 0 {
            self.reserve_(32)
            var at = self.len
            if neg { self.data[at] = 45; at += 1 }
            var n: i32 = 0
            unsafe { n = kairo_rt_fmt_f32(unsafe &self.data[at], 31, v, -1, 103) }
            self.cp_len += (at - self.len) + (n as usize)
            self.len = at + (n as usize)
            return
        }
        var slot = self.float_open_(spec)
        var n: i32 = 0
        unsafe { n = kairo_rt_fmt_f32(unsafe &self.data[slot], FmtBuf::float_cap_(spec), v, FmtBuf::prec_(spec) as i32, FmtBuf::conv_(spec)) }
        self.number_(&self.data[slot], n as usize, neg, spec)
    }

    pub inline fn put_f64(self, v: f64, spec: u64) {
        var neg = false
        unsafe { neg = (FmtBuf::bits64_((&v) as unsafe *const u8, 0) >> 63) != 0 }
        if spec == 0 {
            // Shortest f64 text is at most 24 bytes: written in place, no
            // digit slot, no move.
            self.reserve_(32)
            var at = self.len
            if neg { self.data[at] = 45; at += 1 }
            var n: i32 = 0
            unsafe { n = kairo_rt_fmt_f64(unsafe &self.data[at], 31, v, -1, 103) }
            self.cp_len += (at - self.len) + (n as usize)
            self.len = at + (n as usize)
            return
        }
        var slot = self.float_open_(spec)
        var n: i32 = 0
        unsafe { n = kairo_rt_fmt_f64(unsafe &self.data[slot], FmtBuf::float_cap_(spec), v, FmtBuf::prec_(spec) as i32, FmtBuf::conv_(spec)) }
        self.number_(&self.data[slot], n as usize, neg, spec)
    }

    // FIXME: add back once the Constant Eval Folder is in.
    // pub inline fn put_f80(self, v: f80, spec: u64) {
    //     var neg = false
    //     unsafe { neg = (FmtBuf::bits16_((&v) as unsafe *const u8, 8) >> 15) != 0 }   // x87 extended: the sign is bit 79
    //     var slot = self.float_open_(spec)
    //     var n: i32 = 0
    //     unsafe { n = kairo_rt_fmt_f80(unsafe &self.data[slot], FmtBuf::float_cap_(spec), v, FmtBuf::prec_(spec) as i32, FmtBuf::conv_(spec)) }
    //     self.number_(&self.data[slot], n as usize, neg, spec)
    // }

    pub inline fn put_f128(self, v: f128, spec: u64) {
        var lo: u64 = 0
        var hi: u64 = 0
        unsafe {
            var unsafe *p = (&v) as unsafe *const u8
            lo = FmtBuf::bits64_(p, 0)
            hi = FmtBuf::bits64_(p, 8)
        }
        var slot = self.float_open_(spec)
        var n: i32 = 0
        unsafe { n = kairo_rt_fmt_f128(unsafe &self.data[slot], FmtBuf::float_cap_(spec), hi, lo, FmtBuf::prec_(spec) as i32, FmtBuf::conv_(spec)) }
        self.number_(&self.data[slot], n as usize, (hi >> 63) != 0, spec)
    }

    // TODO(rt): f8e4m3 / f8e5m2 / f256 / f512 wait on ::kairo::rt::* having
    // a C++ definition. The f8 entries in rt/fmt.h take the byte; the corelib
    // pair need an entry taking the limbs. Same shape as the puts above.

    /// Little-endian integer of the bytes at p[off..]. Any pointer may be
    /// read as bytes; clang turns these into one load.
    priv static fn bits16_(p: unsafe *const u8, off: usize) -> u16 {
        return (p[off] as u16) | ((p[off + 1] as u16) << 8)
    }

    priv static fn bits32_(p: unsafe *const u8, off: usize) -> u32 {
        return (p[off] as u32) | ((p[off + 1] as u32) << 8) | ((p[off + 2] as u32) << 16) | ((p[off + 3] as u32) << 24)
    }

    priv static fn bits64_(p: unsafe *const u8, off: usize) -> u64 {
        return (FmtBuf::bits32_(p, off) as u64) | ((FmtBuf::bits32_(p, off + 4) as u64) << 32)
    }

    /// 'g', 'e' or 'E' for the runtime, from the spec's base and upper bits.
    priv static fn conv_(spec: u64) -> u8 {
        if FmtBuf::base_(spec) != 1 { return 103 }                          // g
        var e: u8 = if (FmtBuf::flags_(spec) & 8) != 0 => 69 else => 101    // E e
        return e
    }

    /// Bytes the digits can take: the precision, the point, an exponent,
    /// and `inf` / `nan` headroom.
    priv static fn float_cap_(spec: u64) -> usize {
        var prec = FmtBuf::prec_(spec)
        var p: usize = if prec >= 0 => prec as usize else => 0
        return p + 48
    }

    /// Reserves the padded result AND the digit slot above it; returns the
    /// slot's offset. number_ never moves the buffer after this.
    priv fn float_open_(self, spec: u64) -> usize {
        var head   = FmtBuf::width_(spec) * 4 + 8       // sign, prefix, every pad byte at four bytes each
        var digits = FmtBuf::float_cap_(spec)
        self.reserve_(head + digits + digits)
        return self.len + head + digits
    }

    /// `<name> @ 0x<hex>`, or `&null`. `name` is the pointee's spelling, a
    /// constant at the call site.
    pub fn put_ptr(self, addr: usize, name: *const u8, name_len: usize, spec: u64) {
        if addr == 0 {
            var s = "&null"
            self.text(s.as_ptr(), s.length(), s.codepoints())
            return
        }
        self.text(name, name_len, FmtBuf::cp_count_(name, name_len))
        var at = " @ 0x"
        self.text(at.as_ptr(), at.length(), at.codepoints())
        var one: u64 = 1
        var hex = one << 55
        self.int64_(addr as u64, false, hex)
    }

    /// Hands the buffer over. The result owns it: cap > 0.
    pub inline fn finish(self) -> string {
        var s = string()
        if self.spilled_() {
            // Heap already: hand the block over as it is.
            self.data[self.len] = 0
            s.place(d: self.data as const *u8, l: self.len, c: self.cp_len, ca: self.cap + 1)
        } else {
            // Inline: one allocation of exactly len + 1.
            var unsafe *h = alloc_raw(self.len + 1, 1)
            @unlikely if h == &null { oom(self.len + 1, 1) }
            unsafe {
                __builtin_copy(h, &self.inline_[0] as unsafe *u8, self.len)
                *(h + self.len) = 0
                var *hs = h as *u8
                s.place(d: hs as const *u8, l: self.len, c: self.cp_len, ca: self.len + 1)
            }
        }
        self.data = &null
        self.len  = 0
        self.cap  = 0
        return s
    }

    /// The text so far as a borrowed string (capacity 0): valid until this
    /// FmtBuf is written again or destroyed. NUL-terminated like every string.
    pub inline fn view(self) -> string {
        self.data[self.len] = 0
        var s = string()
        s.place(d: self.data as const *u8, l: self.len, c: self.cp_len, ca: 0)
        return s
    }

    /// Empties the buffer, keeping its storage (inline or heap) for reuse.
    pub inline fn clear(self) {
        self.len    = 0
        self.cp_len = 0
    }

    // --- capacity ----------------------------------------------------------------

    priv inline fn reserve_(self, n: usize) {
        if self.len + n > self.cap { self.grow_(self.len + n) }
    }

    priv fn grow_(self, need: usize) {
        var nc = self.cap * 2
        if nc < need { nc = need }
        if self.spilled_() {
            var q: unsafe *u8 = &null
            unsafe { q = resize_raw(self.data as unsafe *u8, self.cap + 1, nc + 1, 1) }
            @unlikely if q == &null { oom(nc + 1, 1) }
            unsafe { self.data = q as *u8 }
        } else {
            // First spill (or reuse after finish(), when data is null): copy
            // what inline_ holds into a fresh block.
            var unsafe *h = alloc_raw(nc + 1, 1)
            @unlikely if h == &null { oom(nc + 1, 1) }
            unsafe {
                if self.data != &null { __builtin_copy(h, &self.inline_[0] as unsafe *u8, self.len) }
                self.data = h as *u8
            }
        }
        self.cap = nc
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
    priv static fn fill_(spec: u64)  -> u32   { var f = ((spec >> 32) & 0x1FFFFF) as u32; return if f != 0 => f else => 32 }
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
        var pad: usize = if width > n => width - n else => 0
        var right = self.pad_open_(pad, spec, dflt)
        self.text(p, n, n)
        self.pad_(right, FmtBuf::fill_(spec))
    }

    // --- numbers ----------------------------------------------------------------------

    priv static fn digit_(d: u8, upper: bool) -> u8 {
        if d < 10 { return 48 + d }
        return (if upper => 55 else => 87) + d            // 'A' - 10 / 'a' - 10
    }

    /// Sign, `0x`/`0o`/`0b`, zero-padding after them, fill-padding around
    /// them: the one place every number's spec is applied. \p p holds the
    /// digits only.
    priv fn number_(self, p: *const u8, n: usize, neg: bool, spec: u64) {
        // `{x}` with no spec: the sign and the digits, one copy, len and
        // cp_len written once (per-byte byte_() stores both on every digit,
        // since the compiler cannot keep fields in registers across stores
        // through data).
        if spec == 0 {
            var at = self.len
            var total = n + (if neg => 1 else => 0)
            self.reserve_(total)
            if neg { self.data[at] = 45; at += 1 }
            unsafe { __builtin_copy(&self.data[at] as unsafe *u8, p as unsafe *u8, n) }
            self.len    = at + n
            self.cp_len += total
            return
        }
        var flags = FmtBuf::flags_(spec)
        var base  = FmtBuf::base_(spec)
        var sign: u8 = 0
        if neg { sign = 45 } else if (flags & 1) != 0 { sign = 43 }          // '-' '+'
        var pfx: usize = if (flags & 2) != 0 => (if base != 0 => 2 else => 0) else => 0
        var body  = n + pfx + (if sign != 0 => 1 else => 0)
        var width = FmtBuf::width_(spec)
        var pad: usize = if width > body => width - body else => 0
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
        var x: u8 = if (flags & 8) != 0 => 88 else => 120                      // X x
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
            // Two digits per division, from the pair table.
            while mag >= 100 {
                var q = mag / 100
                var r = ((mag - q * 100) * 2) as usize
                i -= 2
                tmp[i]     = DIGIT_PAIRS[r]
                tmp[i + 1] = DIGIT_PAIRS[r + 1]
                mag = q
            }
            if mag >= 10 {
                var r = (mag * 2) as usize
                i -= 2
                tmp[i]     = DIGIT_PAIRS[r]
                tmp[i + 1] = DIGIT_PAIRS[r + 1]
            } else {
                i -= 1
                tmp[i] = (48 + mag) as u8
            }
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