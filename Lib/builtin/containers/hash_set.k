/// --- The Kairo Project ------------ Lib/builtin/containers/hash_set.k --- ///
///
///   The HashSet lang item: `{T}`. Layouts are the ABI; bodies live in std
///   and the runtime.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

pub struct <T> HashSet {
    var data: *T
    var len:  usize
    var cap:  usize

    fn HashSet(self)
}
