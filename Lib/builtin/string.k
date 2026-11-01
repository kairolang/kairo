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
}