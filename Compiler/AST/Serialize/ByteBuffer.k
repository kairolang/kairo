/// --- The Kairo Project ------------------- AST/Serialize/ByteBuffer.k --- ///
///
///   ByteWriter / ByteReader: a growable byte buffer and a bounds-checked
///   cursor over one, with the three encodings the AST format uses: fixed
///   little-endian words, LEB128 varints, and zigzag varints for signed
///   values. Nothing here knows about the AST; any binary format can use it.
///
///   A reader never faults on bad input: reading past the end sets `failed`
///   and yields zero, and the caller checks `failed` once at the end of a
///   section instead of after every field.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"

pub class ByteWriter {
    pub var buf: [u8]

    pub fn ByteWriter(self) { }

    pub inline fn size(const self) -> usize {
        return self.buf.size()
    }

    pub inline fn clear(self) {
        self.buf.clear()
    }

    pub inline fn put_u8(self, v: u8) {
        self.buf.push_back(v)
    }

    pub fn put_u32le(self, v: u32) {
        self.buf.push_back((v & 0xFF) as u8)
        self.buf.push_back(((v >> 8) & 0xFF) as u8)
        self.buf.push_back(((v >> 16) & 0xFF) as u8)
        self.buf.push_back(((v >> 24) & 0xFF) as u8)
    }

    pub fn put_u64le(self, v: u64) {
        self.put_u32le((v & 0xFFFFFFFF) as u32)
        self.put_u32le((v >> 32) as u32)
    }

    /// Overwrites the four bytes at \p at: a length prefix reserved before
    /// its payload was written.
    pub fn patch_u32le(self, at: usize, v: u32) {
        self.buf[at]     = (v & 0xFF) as u8
        self.buf[at + 1] = ((v >> 8) & 0xFF) as u8
        self.buf[at + 2] = ((v >> 16) & 0xFF) as u8
        self.buf[at + 3] = ((v >> 24) & 0xFF) as u8
    }

    /// LEB128: seven bits per byte, low group first, high bit = "more".
    pub fn put_varint(self, v: u64) {
        var x = v
        while x >= 0x80 {
            self.buf.push_back(((x & 0x7F) | 0x80) as u8)
            x = x >> 7
        }

        self.buf.push_back(x as u8)
    }

    /// Zigzag, so a small negative number is a short varint too.
    pub fn put_svarint(self, v: i64) {
        var u = ((v as u64) << 1) ^ ((v >> 63) as u64)
        self.put_varint(u)
    }

    pub fn put_bytes(self, p: unsafe *const u8, n: usize) {
        self.buf.reserve(self.buf.size() + n)
        for var i: usize = 0; i < n; ++i {
            self.buf.push_back(p[i])
        }
    }

    pub fn put_writer(self, const other: ByteWriter) {
        var n = other.buf.size()
        self.buf.reserve(self.buf.size() + n)
        for var i: usize = 0; i < n; ++i {
            self.buf.push_back(other.buf[i])
        }
    }

    pub fn bytes(const self) -> unsafe *const u8 {
        if self.buf.size() == 0 {
            return &null
        }

        return unsafe (self.buf.data() as unsafe *const u8)
    }
}

pub class ByteReader {
    pub var data:   unsafe *const u8 = &null
    pub var len:    usize            = 0
    pub var pos:    usize            = 0
    pub var failed: bool             = false

    pub fn ByteReader(self) { }

    pub fn ByteReader(self, data: unsafe *const u8, len: usize) {
        self.data = data
        self.len  = len
    }

    pub inline fn remaining(const self) -> usize {
        if self.pos >= self.len {
            return 0
        }

        return self.len - self.pos
    }

    pub inline fn at_end(const self) -> bool {
        return self.pos >= self.len
    }

    pub fn get_u8(self) -> u8 {
        if self.pos >= self.len {
            self.failed = true
            return 0
        }

        var v = self.data[self.pos]
        self.pos += 1
        return v
    }

    pub fn get_u32le(self) -> u32 {
        var b0 = self.get_u8() as u32
        var b1 = self.get_u8() as u32
        var b2 = self.get_u8() as u32
        var b3 = self.get_u8() as u32
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    pub fn get_u64le(self) -> u64 {
        var lo = self.get_u32le() as u64
        var hi = self.get_u32le() as u64
        return lo | (hi << 32)
    }

    pub fn get_varint(self) -> u64 {
        var out:   u64 = 0
        var shift: u64 = 0
        // Ten groups carry 70 bits: an eleventh byte is not a u64.
        for var i: usize = 0; i < 10; ++i {
            var b = self.get_u8() as u64
            out = out | ((b & 0x7F) << shift)
            if (b & 0x80) == 0 {
                return out
            }

            shift += 7
        }

        self.failed = true
        return 0
    }

    pub fn get_svarint(self) -> i64 {
        var u = self.get_varint()
        return ((u >> 1) as i64) ^ (-((u & 1) as i64))
    }

    /// The next \p n bytes, in place; null (and `failed`) when fewer remain.
    pub fn get_bytes(self, n: usize) -> unsafe *const u8 {
        if n > self.remaining() {
            self.failed = true
            self.pos    = self.len
            return &null
        }

        var p = unsafe (self.data + self.pos)
        self.pos += n
        return p
    }

    /// A count that the rest of the buffer could hold at one byte each: a
    /// damaged length never becomes an allocation of that size.
    pub fn get_count(self) -> usize {
        var n = self.get_varint() as usize
        if n > self.remaining() {
            self.failed = true
            return 0
        }

        return n
    }
}
