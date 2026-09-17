/// --- The Kairo Project ------------------------- Lib/builtin/string.k --- ///
///
///   The `string` lang item. Declared under the name users spell.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

pub struct string {
    var data: *u8
    var len:  usize

    fn string(self)
    fn length(const self) -> usize
}
