/// builtin/string.k

import alloc_raw::{
    alloc_raw,
    free_raw,
    oom,
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
priv eval ASCII_BIT:  usize = 4 // set: every byte is ASCII, so codepoints == bytes
priv eval LEN_SHIFT:  usize = 3
priv eval MAX_LEN:    usize = usize::MAX >> LEN_SHIFT

// BODY-MIN: the empty string's bytes, a literal object `[cp_len = 0][NUL]`.
priv static EMPTY: [usize; 2] = [0, 0]

// BODY-MIN: the codepoints in `n` bytes at `p`, one byte at a time.
@pure priv fn count_cps_(p: *const u8, n: usize) -> usize {
    var c: usize = 0
    for var i: usize = 0; i < n; ++i {
        if (p[i] & 0xC0) != 0x80 {
            c += 1
        }
    }

    return c
}

// BODY-MIN: the char whose first byte is `p[i]`; the bytes are valid UTF-8.
@pure priv fn decode_(p: *const u8, i: usize) -> char {
    var b0 = p[i] as u32
    if b0 < 0x80 {
        return b0
    }

    if b0 < 0xE0 {
        return ((b0 & 0x1F) << 6) | ((p[i + 1] as u32) & 0x3F)
    }

    if b0 < 0xF0 {
        return (((b0 & 0x0F) << 12) | (((p[i + 1] as u32) & 0x3F) << 6) | ((p[i + 2] as u32) & 0x3F))
    }

    return (((b0 & 0x07) << 18) | (((p[i + 1] as u32) & 0x3F) << 12) | (((p[i + 2] as u32) & 0x3F) << 6) | ((p[i + 3] as u32) & 0x3F))
}

// BODY-MIN: bytes in the UTF-8 form of the char that starts with `b`.
@pure priv fn width_(b: u8) -> usize {
    if b < 0x80 {
        return 1
    }

    if b < 0xE0 {
        return 2
    }

    if b < 0xF0 {
        return 3
    }

    return 4
}

pub eval NO_MATCH: usize = usize::MAX // start of the range a Pattern returns on a miss

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
        __builtin_trap() // BODY-TODO
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
///   heap     owned, NUL-terminated;          [cap][cp_len] sit just before the bytes
/// Two words: 16 bytes on 64-bit, 8 on 32-bit. Length is `meta >> LEN_SHIFT`.
/// Every index is a byte offset. Slicing, trim and split return views and
/// never count: a view carries the ASCII bit of what it was cut from.
/// Codepoint count is O(1) for heap, literal and any ASCII view; a view of
/// non-ASCII text counts when asked, each time it is asked.
/// MOVE-ONLY: no copy ctor. Duplication is spelled out:
///   copy()      keeps the state (view -> view, literal -> literal: free; heap allocates)
///   to_owned()  always heap
///   view()      borrows, never allocates
@relocatable
pub class string {
    priv union Ptr {
        var ro: *const u8? // view, literal
        var rw: *u8?       // heap
    }

    priv var p:    Self::Ptr // never null: the empty string is a literal
    priv var meta: usize     // bits 0..1 state, bit 2 ASCII, bits 3.. len in bytes

    pub fn string(self) { // the empty literal
        // BODY-MIN
        unsafe {
            self.p.ro = (&EMPTY[1]) as unsafe *const u8 as *const u8
        }

        self.meta = ASCII_BIT | ST_LIT
    }

    // c/c++ conversions:
    pub fn string(self, c: unsafe *const __builtin_c_char) {
        // BODY-MIN
        unsafe {
            var unsafe *q       = c as unsafe *const u8
            var        n: usize = 0
            while q[n] != 0 {
                n += 1
            }

            self.init_copy_(q as *const u8, n)
        }
    }

    // `string(const c: *__builtin_c_char)` is not declared: a `const` parameter of
    // pointer type is a pointer to const in C++, the signature of the
    // `unsafe *const __builtin_c_char` form above.
    pub fn string(self, c: unsafe *__builtin_c_char) {
        // BODY-MIN
        unsafe {
            var unsafe *q       = c as unsafe *const u8
            var        n: usize = 0
            while q[n] != 0 {
                n += 1
            }

            self.init_copy_(q as *const u8, n)
        }
    }

    pub fn <S impl ByteRange> string(self, const s: S) { // copies s.size() bytes from s.data(); names no C++ type
        // BODY-MIN
        unsafe {
            self.init_copy_(s.data() as unsafe *const u8 as *const u8, s.size())
        }
    }

    // kairo conversions:
    pub fn string(self, const c: *u8) {
        // BODY-MIN
        var n: usize = 0
        while c[n] != 0 {
            n += 1
        }

        self.init_copy_(c as *const u8, n)
    }

    pub fn string(self, const b: [const u8;]) { // copies all bytes
        // BODY-MIN
        var n = b.size()
        unsafe {
            if n == 0 {
                self.init_copy_((&EMPTY[1]) as unsafe *const u8 as *const u8, 0)
            } else {
                self.init_copy_(&b[0], n)
            }
        }
    }

    pub fn string(self, d: *const u8, n: usize) { // copies n bytes
        // BODY-MIN
        self.init_copy_(d, n)
    }

    pub fn string(self, c: char, n: usize) {
        __builtin_trap() // BODY-TODO
    }

    /// What a string literal lowers to; nothing else calls it. `lit` is the first
    /// byte of a rodata object `[cp_len: usize][bytes][0]`, `len` its byte count
    /// and `cp_len` its codepoint count, all three constants at the call.
    prot fn string(self, lit: *const u8, len: usize, cp_len: usize) {
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

    // BODY-MIN: the funnel. `p` is never null, so its word is read as a plain pointer.
    @pure priv inline fn raw_(const self) -> *const u8 {
        unsafe {
            return *(&self.p as unsafe *const Self::Ptr as unsafe *const *const u8)
        }
    }

    @pure priv inline fn state_(const self) -> usize {
        return self.meta & STATE_MASK
    }

    // The header word `back` words before the bytes: 1 is cp_len (literal, heap), 2 is cap (heap).
    @pure priv inline fn hdr_(const self, back: usize) -> usize {
        unsafe {
            return *((self.raw_() as unsafe *const u8 as unsafe *const usize) - back)
        }
    }

    priv inline fn set_hdr_(self, back: usize, v: usize) {
        unsafe {
            *((self.raw_() as unsafe *const u8 as unsafe *usize) - back) = v
        }
    }

    // A heap block with room for `cap` bytes and the NUL; returns the bytes.
    priv static fn block_(cap: usize) -> unsafe *u8 {
        var        total = 2 * sizeof(usize) + cap + 1
        var unsafe *b    = alloc_raw(total, alignof(usize))
        if b == &null {
            oom(total, alignof(usize))
        }

        unsafe {
            *(b as unsafe *usize) = cap
            return b + 2 * sizeof(usize)
        }
    }

    // Sets this string, which owns nothing, to a copy of `n` bytes at `d`.
    priv fn init_copy_(self, d: *const u8, n: usize) {
        if n == 0 {
            unsafe {
                self.p.ro = (&EMPTY[1]) as unsafe *const u8 as *const u8
            }

            self.meta = ASCII_BIT | ST_LIT
            return
        }

        if n > MAX_LEN {
            string::too_long()
        }

        var unsafe *b = string::block_(n)
        unsafe {
            __builtin_copy(b, d as unsafe *const u8, n)
            b[n]      = 0
            self.p.rw = b as *u8
        }

        var cps = count_cps_(d, n)
        self.meta = (n << LEN_SHIFT) | ST_HEAP
        if cps == n {
            self.meta = self.meta | ASCII_BIT
        }

        self.set_hdr_(1, cps)
    }

    priv fn release_(self) {
        if self.state_() == ST_HEAP {
            unsafe {
                free_raw(
                    (self.raw_() as unsafe *const u8 as unsafe *u8) - 2 * sizeof(usize),
                    2 * sizeof(usize) + self.hdr_(2) + 1,
                    alignof(usize),
                )
            }
        }
    }

    // Appends `n` bytes at `d` holding `cps` codepoints. `d` may point into this string.
    priv fn append_(self, d: *const u8, n: usize, cps: usize) {
        if n == 0 {
            return
        }

        var len   = self.meta >> LEN_SHIFT
        var total = len + n
        if total > MAX_LEN {
            string::too_long()
        }

        var all = self.codepoints() + cps
        if self.state_() == ST_HEAP && total <= self.hdr_(2) {
            unsafe {
                var unsafe *dst = self.raw_() as unsafe *const u8 as unsafe *u8
                __builtin_move_mem(dst + len, d as unsafe *const u8, n)
                dst[total] = 0
            }
        } else {
            var cap = total * 2
            if cap < 16 {
                cap = 16
            }

            var unsafe *b = string::block_(cap)
            unsafe {
                __builtin_copy(b, self.raw_() as unsafe *const u8, len)
                __builtin_copy(b + len, d as unsafe *const u8, n)
                b[total] = 0
            }

            self.release_()
            unsafe {
                self.p.rw = b as *u8
            }
        }

        self.meta = (total << LEN_SHIFT) | ST_HEAP
        if all == total {
            self.meta = self.meta | ASCII_BIT
        }

        self.set_hdr_(1, all)
    }

    @move pub fn string(self, other: Self) { // bitwise; other becomes the empty literal
        // BODY-MIN
        self.p.ro = other.raw_()
        self.meta = other.meta
        unsafe {
            other.p.ro = (&EMPTY[1]) as unsafe *const u8 as *const u8
        }

        other.meta = ASCII_BIT | ST_LIT
    }

    pub fn op finally(self) { // frees only when heap
        self.release_() // BODY-MIN
    }

    @hot_path pub fn op [] (const self, b: usize) -> char { // char starting at byte b; traps off a boundary
        // BODY-MIN
        if b >= self.size() || !self.is_char_boundary(b) {
            self.boundary_fail(b)
        }

        return decode_(self.raw_(), b)
    }

    pub fn op [] (const self, r: Range<usize>) -> string { // view; traps off a boundary
        __builtin_trap() // BODY-TODO
    }

    pub fn op [] (const self, r: RangeFrom<usize>) -> string {
        __builtin_trap() // BODY-TODO
    }

    pub fn op [] (const self, r: RangeTo<usize>) -> string {
        __builtin_trap() // BODY-TODO
    }

    pub fn op in (const self) -> yield char {
        // BODY-MIN
        var i: usize = 0
        var n        = self.size()
        var *p       = self.raw_()
        while i < n {
            yield decode_(p, i)
            i += width_(p[i])
        }
    }

    @hot_path pub fn op += (self, const o: string) { // a + b is derived: MOVES a, then +=
        // BODY-MIN
        self.append_(o.raw_(), o.size(), o.codepoints())
    }

    // slow paths, kept out of every inlined caller. The one fast path is
    // heap with room; view, literal and a full heap buffer land here.
    eval if defined!(__x86_64__) || defined!(__aarch64__) {
        @cold_path @preserve_most @no_inline
        priv fn grow(self, need: usize) {    // view/literal -> heap, or realloc geometric
            __builtin_trap() // BODY-TODO
        }

        @cold_path @preserve_most @no_inline
        priv fn make_owned(self) {    // view/literal -> heap, exact size + NUL
            __builtin_trap() // BODY-TODO
        }
    } else {
        @cold_path @no_inline
        priv fn grow(self, need: usize) {
            __builtin_trap() // BODY-TODO
        }

        @cold_path @no_inline
        priv fn make_owned(self) {
            __builtin_trap() // BODY-TODO
        }
    }

    @pure @no_inline
    priv fn scan_codepoints(const self) -> usize { // a view without the ASCII bit
        // BODY-MIN
        return count_cps_(self.raw_(), self.meta >> LEN_SHIFT)
    }

    @cold_path @no_inline
    priv fn boundary_fail(const self, b: usize) -> ! { // op [] off a char boundary or out of range
        __builtin_trap() // BODY-TODO
    }

    @cold_path @no_inline
    priv static fn too_long() -> ! { // length would pass MAX_LEN
        __builtin_trap() // BODY-TODO
    }
}

extend string impl Eq {
    fn op == (const self, const o: string) -> bool {
        // BODY-MIN
        var n = self.size()
        if n != o.size() {
            return false
        }

        unsafe {
            return __builtin_compare_mem(
                self.raw_() as unsafe *const u8,
                o.raw_() as unsafe *const u8,
                n,
            ) == 0
        }
    }
}

extend string impl Ord {
    fn op <=> (const self, const o: string) -> Ordering {
        // BODY-MIN
        var a      = self.size()
        var b      = o.size()
        var n      = if a < b => a else => b
        var c: i32 = 0
        unsafe {
            c = __builtin_compare_mem(
                self.raw_() as unsafe *const u8,
                o.raw_() as unsafe *const u8,
                n,
            )
        }

        if c < 0 {
            return Ordering::Less
        }

        if c > 0 {
            return Ordering::Greater
        }

        if a < b {
            return Ordering::Less
        }

        if a > b {
            return Ordering::Greater
        }

        return Ordering::Equal
    }
}

extend string impl Hash {
    fn hash(const self, @inout h: Hasher) {
        __builtin_trap() // BODY-TODO
    }
}

extend string impl Default {
    static fn make_default() -> string {
        // BODY-MIN
        return string()
    }
}

extend string impl Append {
    fn append_to(const self, @inout out: string) {
        __builtin_trap() // BODY-TODO
    }
}

extend string impl Pattern {
    fn find_in(const self, const hay: string, from: usize) -> (usize, usize) {
        __builtin_trap() // BODY-TODO
    }

    fn rfind_in(const self, const hay: string, to: usize) -> (usize, usize) {
        __builtin_trap() // BODY-TODO
    }
}

extend string {
    pub static fn with_capacity(n: usize) -> string {
        __builtin_trap() // BODY-TODO
    }

    pub static fn from_utf8(const b: [const u8;]) -> string? { // null on invalid UTF-8
        __builtin_trap() // BODY-TODO
    }

    // state
    pub fn copy(const self) -> string { // keeps the state
        // BODY-MIN
        if self.state_() == ST_HEAP {
            return string(self.raw_(), self.size())
        }

        var s = string()
        s.p.ro = self.raw_()
        s.meta = self.meta
        return s
    }

    pub fn to_owned(const self) -> string {
        // BODY-MIN
        return string(self.raw_(), self.size())
    }

    pub fn view(const self) -> string {
        // BODY-MIN
        var s = string()
        s.p.ro = self.raw_()
        s.meta = (self.meta & ~STATE_MASK) | ST_VIEW
        return s
    }

    @pure pub fn is_owned(const self) -> bool { // heap
        // BODY-MIN
        return self.state_() == ST_HEAP
    }

    @pure pub fn is_view(const self) -> bool { // borrowed, not a literal
        // BODY-MIN
        return self.state_() == ST_VIEW
    }

    @pure pub fn is_static(const self) -> bool { // a literal
        // BODY-MIN
        return self.state_() == ST_LIT
    }

    // size
    @pure pub fn size(const self) -> usize { // bytes
        // BODY-MIN
        return self.meta >> LEN_SHIFT
    }

    @pure pub fn codepoints(const self) -> usize { // O(1), except a non-ASCII view: O(n)
        // BODY-MIN
        if (self.meta & ASCII_BIT) != 0 {
            return self.meta >> LEN_SHIFT
        }

        if self.state_() == ST_VIEW {
            return self.scan_codepoints()
        }

        return self.hdr_(1)
    }

    @pure pub fn is_empty(const self) -> bool {
        // BODY-MIN
        return (self.meta >> LEN_SHIFT) == 0
    }

    @pure pub fn is_ascii(const self) -> bool { // O(1), except a non-ASCII view: O(n)
        // BODY-MIN
        return (self.meta & ASCII_BIT) != 0 || self.codepoints() == self.size()
    }

    @pure pub fn capacity(const self) -> usize { // 0 unless heap
        // BODY-MIN
        if self.state_() == ST_HEAP {
            return self.hdr_(2)
        }

        return 0
    }

    pub fn reserve(self, bytes: usize) {
        __builtin_trap() // BODY-TODO
    }

    pub fn shrink_to_fit(self) {
        __builtin_trap() // BODY-TODO
    }

    // access
    @pure pub fn get(const self, b: usize) -> char? {
        // BODY-MIN
        if b >= self.size() || !self.is_char_boundary(b) {
            return null
        }

        return decode_(self.raw_(), b)
    }

    @pure pub fn char_at(const self, cp: usize) -> char? { // O(1) if ASCII, else O(n)
        // BODY-MIN
        var n        = self.size()
        var *p       = self.raw_()
        var i: usize = 0
        var k: usize = 0
        while i < n {
            if k == cp {
                return decode_(p, i)
            }

            i += width_(p[i])
            k += 1
        }

        return null
    }

    @pure pub fn byte_offset(const self, cp: usize) -> usize? { // O(1) if ASCII, else O(n)
        // BODY-MIN
        var n        = self.size()
        var *p       = self.raw_()
        var i: usize = 0
        var k: usize = 0
        while i < n {
            if k == cp {
                return i
            }

            i += width_(p[i])
            k += 1
        }

        if k == cp {
            return n
        }

        return null
    }

    @pure pub fn first(const self) -> char? {
        // BODY-MIN
        if self.size() == 0 {
            return null
        }

        return decode_(self.raw_(), 0)
    }

    @pure pub fn last(const self) -> char? {
        // BODY-MIN
        var i = self.size()
        if i == 0 {
            return null
        }

        var *p = self.raw_()
        i -= 1
        while i > 0 && (p[i] & 0xC0) == 0x80 {
            i -= 1
        }

        return decode_(p, i)
    }

    @pure pub fn is_char_boundary(const self, b: usize) -> bool {
        // BODY-MIN
        var n = self.size()
        if b >= n {
            return b == n
        }

        return (self.raw_()[b] & 0xC0) != 0x80
    }

    // raw
    pub fn bytes(const self) -> [const u8;] {
        // BODY-MIN
        unsafe {
            return Slice<const u8>(self.raw_() as unsafe *const u8, self.size())
        }
    }

    @pure pub fn data(const self) -> *const u8 {
        // BODY-MIN
        return self.raw_()
    }

    pub fn c_str(self) -> unsafe *const __builtin_c_char { // a view becomes heap first
        // BODY-MIN
        if self.state_() == ST_VIEW {
            var o = string(self.raw_(), self.size())
            self.p.ro = o.raw_()
            self.meta = o.meta
            unsafe {
                o.p.ro = (&EMPTY[1]) as unsafe *const u8 as *const u8
            }

            o.meta = ASCII_BIT | ST_LIT
        }

        unsafe {
            return self.raw_() as unsafe *const u8 as unsafe *const __builtin_c_char
        }
    }

    @pure pub fn try_c_str(const self) -> (unsafe *const __builtin_c_char)? { // null on a view; never allocates
        // BODY-MIN
        if self.state_() == ST_VIEW {
            return null
        }

        unsafe {
            return self.raw_() as unsafe *const u8 as unsafe *const __builtin_c_char
        }
    }

    // iteration
    pub fn chars(const self) -> Chars {
        __builtin_trap() // BODY-TODO
    }

    pub fn char_indices(const self) -> yield (usize, char) {
        __builtin_trap() // BODY-TODO
    }

    pub fn lines(const self) -> yield string {
        __builtin_trap() // BODY-TODO
    }

    pub fn fields(const self) -> yield string {
        __builtin_trap() // BODY-TODO
    }

    // search, byte offsets
    pub fn <P impl Pattern> op in (const self, const p: P) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn <P impl Pattern> contains(const self, const p: P) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn <P impl Pattern> starts_with(const self, const p: P) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn <P impl Pattern> ends_with(const self, const p: P) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn <P impl Pattern> find(const self, const p: P) -> usize? {
        __builtin_trap() // BODY-TODO
    }

    pub fn <P impl Pattern> rfind(const self, const p: P) -> usize? {
        __builtin_trap() // BODY-TODO
    }

    pub fn <P impl Pattern> count(const self, const p: P) -> usize {
        __builtin_trap() // BODY-TODO
    }

    // views, no allocation, no counting
    pub fn trim(const self) -> string {
        __builtin_trap() // BODY-TODO
    }

    pub fn trim_start(const self) -> string {
        __builtin_trap() // BODY-TODO
    }

    pub fn trim_end(const self) -> string {
        __builtin_trap() // BODY-TODO
    }

    pub fn <P impl Pattern> trim_matches(const self, const p: P) -> string {
        __builtin_trap() // BODY-TODO
    }

    pub fn <P impl Pattern> strip_prefix(const self, const p: P) -> string? {
        __builtin_trap() // BODY-TODO
    }

    pub fn <P impl Pattern> strip_suffix(const self, const p: P) -> string? {
        __builtin_trap() // BODY-TODO
    }

    pub fn <P impl Pattern> split_once(const self, const p: P) -> (string, string)? {
        __builtin_trap() // BODY-TODO
    }

    pub fn <P impl Pattern> rsplit_once(const self, const p: P) -> (string, string)? {
        __builtin_trap() // BODY-TODO
    }

    /// split / rsplit: the generator BORROWS both `self` and the pattern. In a
    /// `for` header the pattern temporary lives for the loop (language change
    /// 4); a generator stored past its statement (`var it = s.split(sep())`)
    /// dangles, the same class of bug as a stale slice. Until Tether.
    pub fn <P impl Pattern> split(const self, const p: P, max: usize = usize::MAX) -> yield string {
        __builtin_trap() // BODY-TODO
    }

    pub fn <P impl Pattern> rsplit(const self,
                                   const p: P,
                                   max:     usize = usize::MAX) -> yield string {
        __builtin_trap() // BODY-TODO
    }

    // allocating
    pub fn concat(const self, const o: string) -> string {
        // BODY-MIN
        var s = string(self.raw_(), self.size())
        s.append_(o.raw_(), o.size(), o.codepoints())
        return s
    }

    pub fn <P impl Pattern> replace(const self,
                                    const p:  P,
                                    const by: string,
                                    max:      usize = usize::MAX) -> string {
        __builtin_trap() // BODY-TODO
    }

    pub fn repeat(const self, n: usize) -> string {
        __builtin_trap() // BODY-TODO
    }

    pub fn to_ascii_upper(const self) -> string {
        __builtin_trap() // BODY-TODO
    }

    pub fn to_ascii_lower(const self) -> string {
        __builtin_trap() // BODY-TODO
    }

    pub fn pad_start(const self, width: usize, fill: char = ' ') -> string {
        __builtin_trap() // BODY-TODO
    }

    pub fn pad_end(const self, width: usize, fill: char = ' ') -> string {
        __builtin_trap() // BODY-TODO
    }

    // mutation, byte offsets; view and literal become heap first
    @hot_path pub fn push(self, c: char) {
        __builtin_trap() // BODY-TODO
    }

    @hot_path pub fn push_str(self, const s: string) { // counts s while copying it if s is a non-ASCII view
        // BODY-MIN
        self.append_(s.raw_(), s.size(), s.codepoints())
    }

    pub fn <A impl Append> append(self, const v: A) { // formats v onto the end
        __builtin_trap() // BODY-TODO
    }

    pub fn insert(self, at: usize, const s: string) {
        __builtin_trap() // BODY-TODO
    }

    pub fn remove_range(self, r: Range<usize>) {
        __builtin_trap() // BODY-TODO
    }

    pub fn pop(self) -> char? {
        __builtin_trap() // BODY-TODO
    }

    pub fn truncate(self, bytes: usize) {
        __builtin_trap() // BODY-TODO
    }

    pub fn clear(self) {
        // BODY-MIN
        self.release_()
        unsafe {
            self.p.ro = (&EMPTY[1]) as unsafe *const u8 as *const u8
        }

        self.meta = ASCII_BIT | ST_LIT
    }

    // compare, parse
    @pure pub fn eq_ignore_ascii_case(const self, const o: string) -> bool {
        // BODY-MIN
        var n = self.size()
        if n != o.size() {
            return false
        }

        var *a = self.raw_()
        var *b = o.raw_()
        for var i: usize = 0; i < n; ++i {
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

        return true
    }

    pub fn <T impl FromStr> parse(const self) panic(ParseError) -> T {
        __builtin_trap() // BODY-TODO
    }
}

/// Borrows the string it came from. Move-only.
pub class Chars {
    priv var ptr:   *const u8?
    priv var front: usize
    priv var back:  usize

    @move pub fn Chars(self, other: Self) {
        __builtin_trap() // BODY-TODO
    }
}

extend Chars impl DoubleEnded {
    type Item = char
    @hot_path fn next(self) -> char? {
        __builtin_trap() // BODY-TODO
    }

    @hot_path fn next_back(self) -> char? {
        __builtin_trap() // BODY-TODO
    }
}
