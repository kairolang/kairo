/// --- The Kairo Project ------------------------- Lib/builtin/string.k --- ///
///
///   The `string` lang item. Declared under the name users spell.
///
///   UTF-8, and nothing else. `data` is bytes, `len` counts them, `codepoints`
///   counts the codepoints they encode; `len == codepoints` is the ASCII fast
///   path for indexing. `capacity == 0` is the borrow flag: a literal points into
///   static storage and costs no allocation, an owned string has `capacity`
///   bytes of heap behind `data`. Owned strings keep a NUL past `len`, as a
///   literal already does, so a C string view is O(1) for both kinds.
///
///   Ownership. COPY: a copy of an owned string is a deep copy (one block of
///   exactly len + 1 bytes); a copy of a borrowed one shares the static
///   bytes and allocates nothing. The first mutation of a borrowed string
///   (`+=`, `push_back`, `reserve` past its length, the mutable `[]`) moves
///   its bytes to the heap; the literal itself is never written. `cap` is
///   the size of the heap block, NUL slot included, and is exactly what
///   free_raw is handed back: the block comes from the allocator in effect
///   (alloc_raw / resize_raw, Lib/builtin/base/alloc.k), the same one
///   FmtBuf builds f-strings with, so either can free what the other made.
///
///   Moves. A COPY class has one transfer constructor (SC057E), so C++ sees
///   only `string(const string&)` and a move is the deep copy. The copy
///   constructor is the single place a cheap move would land: steal
///   `data` / `cap`, leave the source borrowing EMPTY.
///
///   Performance. The hot members (construction, copy of a borrowed string,
///   the destructor's test, size / empty / [], the no-growth path of `+=`
///   and push_back, comparison) are inline and branch once on `cap`;
///   everything that allocates is an out-of-line @cold_path member.
///
///   Eval. The literal, empty and copy constructors and the destructor are
///   C++ constexpr (NameResolution::_literal_ctor_constexpr): a compile-time
///   string is always borrowed, so the copy's allocation and the
///   destructor's free are on branches a constant expression never takes.
///   Do not add another three-argument constructor: that pass marks every
///   one constexpr as "the literal".
///
///   Placement. Every member is here, users' methods included: a plain
///   `extend` must be in the type's own file (extends.mdx), so Lib/std
///   cannot add them.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import base::ordering::*
import base::intrinsics::*
import alloc_raw::{alloc_raw, free_raw, resize_raw, oom}
import base::c_char::*

/// One NUL byte with static lifetime: what every empty string points at, so
/// `data` is never null and the C string view is valid for every string.
static EMPTY: [u8; 1] = [0]

/// The smallest heap block a growing string takes: appends to a fresh
/// string do not reallocate for every few bytes.
eval MIN_BLOCK: usize = 16

/// The high bit of `cps`: the count is stale. The mutable `[]` hands out a
/// raw byte place and cannot see the write, so it sets this and
/// codepoints() counts the bytes while it is set. A count is at most `len`,
/// so the bit is never a real one; additions keep it (append_ ORs it back).
eval CPS_STALE: usize = usize::MAX ^ (usize::MAX >> 1)

/// 1 when \p b starts a codepoint (is not a UTF-8 continuation byte).
inline fn lead_(b: u8) -> usize { return if (b & 0xC0) != 0x80 => 1 else => 0 }

/// memcmp over safe pointers.
inline fn cmp_(a: *const u8, b: *const u8, n: usize) -> i32 {
    unsafe { return __builtin_compare_mem(a as unsafe *const u8, b as unsafe *const u8, n) }
}

/// The codepoints in n bytes at p.
fn count_cps_(p: *const u8, n: usize) -> usize {
    var c: usize = 0
    for var i: usize = 0; i < n; ++i { c += lead_(p[i]) }
    return c
}

pub class string {
    var data: *const u8
    var len:  usize
    var cps:  usize
    var cap:  usize

    fn place(self, d: *const u8, l: usize, c: usize, ca: usize) {
        self.data = d
        self.len  = l
        self.cps  = c
        self.cap  = ca
    }

    fn string(self) {
        self.data = &EMPTY[0]
        self.len  = 0
        self.cps  = 0
        self.cap  = 0
    }

    /// A literal. Borrowed; StringLowering supplies every count.
    fn string(self, d: *const u8, l: usize, c: usize) {
        self.data = d
        self.len  = l
        self.cps  = c
        self.cap  = 0
    }

    /// NUL-terminated bytes, copied: Stage 0's `string(const char *)` and
    /// `string(const unsigned char *)`.
    fn string(self, c: *const u8) {
        var n: usize = 0
        while c[n] != 0 { ++n }
        self.data = &EMPTY[0]
        self.len  = 0
        self.cps  = 0
        self.cap  = 0
        if n != 0 { self.assign_bytes_(c, n) }
    }

    /// Bytes [0, l), copied (`string(sr.data(), sr.size())`).
    fn string(self, d: *const u8, l: usize) {
        self.data = &EMPTY[0]
        self.len  = 0
        self.cps  = 0
        self.cap  = 0
        if l != 0 { self.assign_bytes_(d, l) }
    }

    /// n copies of the byte c (`string(std::size_t n, char c)` with the
    /// arguments the other way round, so a literal count never reads as a
    /// pointer). Built in place: filling a fresh block avoids the temporary
    /// string and the copy that `string(n)` plus a loop of push_back would pay.
    fn string(self, c: u8, n: usize) {
        self.data = &EMPTY[0]
        self.len  = 0
        self.cps  = 0
        self.cap  = 0
        if n != 0 { self.fill_bytes_(c, n) }
    }

    /// Deep for an owned source, shared for a borrowed one (static bytes
    /// outlive every copy). constexpr (see the file header).
    @copy fn string(self, const other: Self) {
        self.data = other.data
        self.len  = other.len
        self.cps  = other.cps
        self.cap  = 0
        if other.cap != 0 { self.own_exact_() }
    }

    fn op delete(self) {
        if self.cap != 0 {
            unsafe { free_raw(self.data as unsafe *u8, self.cap, 1) }
        }
    }

    // --- reading ------------------------------------------------------------

    inline fn as_ptr(const self) -> *const u8 { return self.data }
    inline fn length(const self) -> usize     { return self.len }
    /// The codepoints the bytes encode. O(1), except after a write through
    /// the mutable `[]`, which leaves the count stale: then the bytes are
    /// counted, on every call, until something replaces the string.
    inline fn codepoints(const self) -> usize {
        @unlikely if (self.cps & CPS_STALE) != 0 { return count_cps_(self.data, self.len) }
        return self.cps
    }
    inline fn capacity(const self) -> usize   { return self.cap }

    /// Byte count; Stage 0's `size()`. Same as length().
    inline fn size(const self) -> usize { return self.len }
    inline fn empty(const self) -> bool { return self.len == 0 }

    /// The bytes, NUL-terminated: Stage 0's `raw()`; same as as_ptr().
    inline fn raw(const self) -> *const u8 { return self.data }

    /// The bytes as a C string, for a C or C++ `const char *` parameter.
    /// O(1): a literal and an owned string both keep a NUL past len. Valid
    /// until the string is next mutated or destroyed.
    inline fn c_str(const self) -> unsafe *const __builtin_c_char {
        unsafe { return self.data as unsafe *const __builtin_c_char }
    }

    /// The byte at `i`, as a place. Unchecked, like C++'s.
    inline fn op [] (const self, i: usize) -> *const u8 { return &self.data[i] }

    /// The byte at `i`, writable: a borrowed string moves to the heap first,
    /// so the literal's static bytes are never written. The write is a raw
    /// byte store this operator never sees, so it marks the count stale
    /// (CPS_STALE) and codepoints() recounts: one OR here, and nothing on
    /// any read path of a string that was never written through `[]`. The
    /// mark is set on a read through this operator too (a non-const
    /// receiver selects it).
    inline fn op [] (self, i: usize) -> *u8 {
        @unlikely if self.cap == 0 { self.own_exact_() }
        self.cps |= CPS_STALE
        unsafe {
            var unsafe *d = (self.data as unsafe *u8) + i
            return d as *u8
        }
    }

    /// Byte-wise ordering. Derives `==`, `!=`, `<`, `>`, `<=`, `>=`. Equal
    /// lengths are tested first: every return on the unequal-length path is
    /// nonzero, so once inlined into `a == b` the compiler drops that path's
    /// compare_mem, and `==` is a length test, then one memcmp.
    inline fn op <=> (const self, const other: string) -> Ordering {
        // Statements, not `if c => Ordering::Less else => ...`: a header
        // spells that conditional's `: ::builtin::...` as `:::builtin`
        // (ticket candidate), and every header includes this body.
        if self.len == other.len {
            if self.data == other.data { return Ordering::Equal }   // copies of one literal
            var e = cmp_(self.data, other.data, self.len)
            if e == 0 { return Ordering::Equal }
            if e < 0 { return Ordering::Less }
            return Ordering::Greater
        }
        var n = if self.len < other.len => self.len else => other.len
        var c = cmp_(self.data, other.data, n)
        if c < 0 { return Ordering::Less }
        if c > 0 { return Ordering::Greater }
        if self.len < other.len { return Ordering::Less }
        return Ordering::Greater
    }

    /// Equality. `<=>` derives one, but an interface requirement (Hash's
    /// `op ==`, for `{string: V}` keys) is met only by a declared operator:
    /// this is that one, the same test the derived form inlines to.
    inline fn op == (const self, const other: string) -> bool {
        if self.len != other.len { return false }
        if self.data == other.data { return true }
        return cmp_(self.data, other.data, self.len) == 0
    }

    /// `n` bytes from byte `pos`, clamped to the string. Copied, except a
    /// borrowed string's suffix, which shares its static, NUL-terminated
    /// bytes.
    fn subslice(const self, pos: usize, n: usize) -> string {
        var p = if pos < self.len => pos else => self.len
        var k = if n < self.len - p => n else => self.len - p
        var r = string()
        if k == 0 { return r }
        if (self.cap == 0) && (p + k == self.len) {
            r.data = &self.data[p]
            r.len  = k
            r.cps  = if self.len == self.cps => k else => count_cps_(&self.data[p], k)   // a stale count is never len
            return r
        }
        r.assign_bytes_(&self.data[p], k)
        return r
    }

    /// Prefix and suffix tests. Stage 0 also takes a single byte; a literal
    /// converts to `string` for free (it is borrowed).
    inline fn starts_with(const self, const needle: string) -> bool {
        if needle.len > self.len { return false }
        return cmp_(self.data, needle.data, needle.len) == 0
    }
    inline fn starts_with(const self, c: u8) -> bool {
        return (self.len != 0) && (self.data[0] == c)
    }
    inline fn ends_with(const self, const needle: string) -> bool {
        if needle.len > self.len { return false }
        return cmp_(&self.data[self.len - needle.len], needle.data, needle.len) == 0
    }
    inline fn ends_with(const self, c: u8) -> bool {
        return (self.len != 0) && (self.data[self.len - 1] == c)
    }

    /// Byte offset of the last occurrence, or usize::MAX when absent
    /// (Stage 0's npos). An empty needle is found at size().
    fn rfind(const self, const needle: string) -> usize {
        if needle.len > self.len { return usize::MAX }
        var i = self.len - needle.len
        while true {
            if cmp_(&self.data[i], needle.data, needle.len) == 0 { return i }
            if i == 0 { break }
            --i
        }
        return usize::MAX
    }
    fn rfind(const self, c: u8) -> usize {
        var i = self.len
        while i != 0 {
            --i
            if self.data[i] == c { return i }
        }
        return usize::MAX
    }

    // --- mutation -----------------------------------------------------------

    /// Concatenation; `+` is derived from it. No call when the block has
    /// room: the growth path is a separate cold member, entered as a tail
    /// call, so the fast path needs no stack frame of its own. Appending a
    /// string to itself is safe: `other.len` is read before a growth can
    /// move `other.data`, which is then the new block.
    inline fn op += (self, const other: string) {
        var k = other.len
        if k == 0 { return }
        @likely if self.len + k < self.cap { self.append_(other.data, k, other.cps); return }
        self.append_slow_(other)
    }

    /// Appends one byte. codepoints() counts it when it starts a codepoint,
    /// so pushing a multibyte character byte by byte counts it once.
    inline fn push_back(self, c: u8) {
        @likely if self.len + 1 < self.cap { self.put_(c); return }
        self.push_slow_(c)
    }

    /// k bytes at p, k > 0, into room the block already has.
    priv inline fn append_(self, p: *const u8, k: usize, c: usize) {
        var n = self.len + k
        unsafe {
            var unsafe *d = self.data as unsafe *u8
            __builtin_copy(d + self.len, p as unsafe *const u8, k)
            d[n] = 0
        }
        self.len = n
        // A stale count on either side stays stale: two set bits would
        // carry out of the sum and clear it.
        self.cps = (self.cps + c) | ((self.cps | c) & CPS_STALE)
    }

    /// One byte into room the block already has.
    priv inline fn put_(self, c: u8) {
        var n = self.len + 1
        unsafe {
            var unsafe *d = self.data as unsafe *u8
            d[self.len] = c
            d[n] = 0
        }
        self.len = n
        self.cps += lead_(c)
    }

    /// Room for at least `n` bytes without another allocation. A borrowed
    /// string asked for no more than it has stays borrowed.
    inline fn reserve(self, n: usize) {
        if (n >= self.cap) && ((self.cap != 0) || (n > self.len)) { self.realloc_(n + 1) }
    }

    // --- slow paths ---------------------------------------------------------

    @cold_path @no_inline
    priv fn append_slow_(self, const other: string) {
        var k = other.len
        self.grow_(self.len + k)
        self.append_(other.data, k, other.cps)
    }

    @cold_path @no_inline
    priv fn push_slow_(self, c: u8) {
        self.grow_(self.len + 1)
        self.put_(c)
    }

    /// Room for `need` bytes plus the NUL: double, at least MIN_BLOCK.
    @cold_path @no_inline
    priv fn grow_(self, need: usize) {
        var want = self.cap * 2
        if want < need + 1 { want = need + 1 }
        if want < MIN_BLOCK { want = MIN_BLOCK }
        self.realloc_(want)
    }

    /// Moves the bytes into a heap block of exactly `block` bytes
    /// (block > len). An owned block is resized; a borrowed string's bytes
    /// are copied out of their static storage.
    @cold_path @no_inline
    priv fn realloc_(self, block: usize) {
        unsafe {
            var p: unsafe *u8 = &null
            if self.cap != 0 {
                p = resize_raw(self.data as unsafe *u8, self.cap, block, 1)
                if p == &null { oom(block, 1) }
            } else {
                p = alloc_raw(block, 1)
                if p == &null { oom(block, 1) }
                __builtin_copy(p, self.data as unsafe *const u8, self.len)
                p[self.len] = 0
            }
            self.data = p as *const u8
        }
        self.cap = block
    }

    /// The copy constructor's and the mutable `[]`'s slow path: the bytes
    /// `data` points at, which this string does not own, into a block of
    /// its own of exactly len + 1 bytes.
    @cold_path @no_inline
    priv fn own_exact_(self) {
        var block = self.len + 1
        unsafe {
            var unsafe *p = alloc_raw(block, 1)
            if p == &null { oom(block, 1) }
            __builtin_copy(p, self.data as unsafe *const u8, self.len)
            p[self.len] = 0
            self.data = p as *const u8
        }
        self.cap = block
    }

    /// Replaces an EMPTY string's contents with a copy of n > 0 bytes at d.
    @cold_path @no_inline
    priv fn assign_bytes_(self, d: *const u8, n: usize) {
        var block = n + 1
        unsafe {
            var unsafe *p = alloc_raw(block, 1)
            if p == &null { oom(block, 1) }
            __builtin_copy(p, d as unsafe *const u8, n)
            p[n] = 0
            self.data = p as *const u8
        }
        self.len = n
        self.cps = count_cps_(d, n)
        self.cap = block
    }

    /// Replaces an EMPTY string's contents with n > 0 copies of c.
    @cold_path @no_inline
    priv fn fill_bytes_(self, c: u8, n: usize) {
        var block = n + 1
        unsafe {
            var unsafe *p = alloc_raw(block, 1)
            if p == &null { oom(block, 1) }
            for var i: usize = 0; i < n; ++i { p[i] = c }
            p[n] = 0
            self.data = p as *const u8
        }
        self.len = n
        // Every copy of c counts the same: a continuation byte repeated is
        // zero codepoints, as count_cps_ would say of the same bytes.
        self.cps = n * lead_(c)
        self.cap = block
    }

    // Not declared:
    //   view() (13) and std_string() (24) return C++'s std::string_view /
    //     std::string, and builtin cannot name a C++ type. They belong in
    //     std, or at the FFI boundary that needs them.
}
