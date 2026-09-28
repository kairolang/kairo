/// --- The Kairo Project ------------------------- Lib/builtin/string.k --- ///
///
///   The `string` lang item. Declared under the name users spell.
///
///   UTF-8, and nothing else. `data` is bytes, `len` counts them, `cp_len`
///   counts the codepoints they encode; `len == cp_len` is the ASCII fast
///   path for indexing. `cap == 0` is the borrow flag: a literal points into
///   static storage and costs no allocation, an owned string has `cap`
///   bytes of heap behind `data`. Owned strings keep a NUL past `len`, as a
///   literal already does, so a C string view is O(1) for both kinds.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

pub struct string {
    var data:   *const u8
    var len:    usize
    var cp_len: usize
    var cap:    usize

    fn string(self) {
        self.data   = &null
        self.len    = 0
        self.cp_len = 0
        self.cap    = 0
    }

    /// A literal. Borrowed; StringLowering supplies every count.
    fn string(self, data: *const u8, len: usize, cp_len: usize) {
        self.data   = data
        self.len    = len
        self.cp_len = cp_len
        self.cap    = 0
    }
}

