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

    @move fn string(self, other: Self) {
        self.data = other.data
        self.len  = other.len
        self.cps  = other.cps
        self.cap  = other.cap

        other.data = &EMPTY[0]
        other.len  = 0
        other.cps  = 0
        other.cap  = 0
    }

    fn as_ptr(const self) -> *const u8 { return self.data }
    fn length(const self) -> usize     { return self.len }
    fn codepoints(const self) -> usize { return self.cps }
    fn capacity(const self) -> usize   { return self.cap }
}