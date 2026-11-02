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
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import base::ordering::*

/// One NUL byte with static lifetime: what every empty string points at, so
/// `data` is never null and the C string view is valid for every string.
static EMPTY: [u8; 1] = [0]

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

    /// TEMPORARY (2026-11-01): copy-only, a shallow copy, until the owning
    /// API lands; it replaced the `@move` constructor (a class declares one
    /// transfer, SC057E). Defaulted, so it stays constexpr for eval
    /// strings. Shares `data`, owned or not: sound only while
    /// string has no destructor. Move-only, every lowering that spills a
    /// string by value (f-string holes, match binders, captures) emitted a
    /// deleted C++ copy; see TICKETS.TXT.
    @copy fn string(self, const other: Self) = default

    inline fn as_ptr(const self) -> *const u8 { return self.data }
    inline fn length(const self) -> usize     { return self.len }
    inline fn codepoints(const self) -> usize { return self.cps }
    inline fn capacity(const self) -> usize   { return self.cap }

    // --- Declared, not yet defined (2026-11-01) ---------------------------
    // The API Compiler/ uses of Stage 0's string, from
    // Scripts/Migration/api_surface.py (private/IMPORTANT/api-surface.md has
    // every site). Counts are Compiler/ call sites. Each is a declaration
    // only: a call links against nothing until its definition lands, out of
    // line (`fn string::size(const self) -> usize { ... }`) or here.

    /// Byte count; Stage 0's `size()` (454). `length()` above (167) is the same.
    fn size(const self) -> usize
    /// `size() == 0` (349).
    fn empty(const self) -> bool

    /// `len` bytes from byte `pos` (77).
    fn subslice(const self, pos: usize, len: usize) -> string

    /// Appends one byte (9).
    fn push_back(self, c: u8)
    /// Grows the capacity to at least `n` bytes (5).
    fn reserve(self, n: usize)

    /// Prefix and suffix tests (18 / 5). Stage 0 also takes a single byte
    /// and a C string; a literal converts to `string`.
    fn starts_with(const self, needle: string) -> bool
    fn starts_with(const self, c: u8) -> bool
    fn ends_with(const self, needle: string) -> bool
    fn ends_with(const self, c: u8) -> bool

    /// Byte offset of the last occurrence, or usize::MAX when absent
    /// (Stage 0's npos) (3).
    fn rfind(const self, needle: string) -> usize
    fn rfind(const self, c: u8) -> usize

    /// The bytes, NUL-terminated: Stage 0's `raw()` (32); same as as_ptr().
    fn raw(const self) -> *const u8
    // Not declared:
    //   c_str() (13), `const char *`: c_char is __builtin_c_char in the
    //     builtin root (module.k), which this file cannot import without a
    //     cycle. Declare it once that alias moves to a file both can import,
    //     or spell it `raw() as unsafe *const c_char` at the FFI call.
    //   view() (13) and std_string() (24) return C++'s std::string_view /
    //     std::string, and builtin cannot name a C++ type. They belong in
    //     std, or at the FFI boundary that needs them.


    // --- Declared only when defined ---------------------------------------
    // These change how existing code resolves the moment they exist, so
    // each lands with its definition, not before: an operator here takes
    // over the compiler's built-in `==` / `[]` / `+=` on strings (a
    // declaration with no body turns every string comparison into a call
    // that links against nothing), and a one-argument constructor makes
    // `x as string` a conversion through it (casting.md).
    //
    // /// NUL-terminated bytes, copied: Stage 0's `string(const char *)` (20)
    // /// and `string(const unsigned char *)` (5).
    // fn string(self, c: *const u8)
    //
    // /// Bytes [0, len), copied (`string(sr.data(), sr.size())`).
    // fn string(self, d: *const u8, l: usize)
    //
    // /// Concatenation (`+=` 950; `+` 3911 is derived from it).
    // fn op += (self, other: string)
    // /// Byte-wise ordering. Derives every comparison: `==` (809), `!=`
    // /// (147), and `<` (7) / `>` (1) for map / set keys. A separate `op ==`
    // /// (a length check first) would shadow the derived one; declaring both
    // /// warns (SC001W) on every compile while either is a declaration only.
    // fn op <=> (const self, other: string) -> Ordering
    // /// The byte at `i`, as a place (266).
    // fn op [] (self, i: usize) -> *u8
    // fn op [] (const self, i: usize) -> *const u8
}