/// --- The Kairo Project -------------- Lib/builtin/containers/vector.k --- ///
///
///   The Vector lang item: `[T]`. Layouts are the ABI; bodies live in std
///   and the runtime. Imports Slice so `[T;]` in its constructor resolves:
///   a builtin file's lang items are bound before its types are resolved,
///   in import order (NameResolution::fill_lang_items).
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import containers::slice::*

/// Growable, owning.
pub struct <T> Vector {
    var data: *T
    var len:  usize
    var cap:  usize

    fn Vector(self)
    fn Vector(self, const items: [T;])

    /// A vector passes where a slice is wanted: a view, nothing copied.
    @implicit pub inline fn op as (self) -> [T;] {
        return Slice<T>(self.data, self.len)
    }
}
