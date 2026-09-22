/// --- The Kairo Project --------------------- Lib/builtin/containers.k --- ///
///
///   The container lang items. `[T;]` is Slice, `[T]` is Vector, `{T}` is
///   HashSet, `{K: V}` is HashMap. `[T; N]` stays a structural array, and is
///   the type of a `[...]` literal with no container target.
///   Layouts are the ABI; bodies live in std and the runtime.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// A view over N contiguous T. `[T;]`, and the type a `[...]` literal
/// takes against a `[T;]` target.
pub struct <T> Slice {
    var data: *T
    var len:  usize

    fn Slice(self, data: *T, len: usize) {
        self.data = data
        self.len  = len
    }
}

/// Growable, owning.
pub struct <T> Vector {
    var data: *T
    var len:  usize
    var cap:  usize

    fn Vector(self)
    fn Vector(self, const items: [T;])
}

pub struct <T> HashSet {
    var data: *T
    var len:  usize
    var cap:  usize

    fn HashSet(self)
}

pub struct <K, V> HashMap {
    var keys:   *K
    var values: *V
    var len:    usize
    var cap:    usize

    fn HashMap(self)
}
