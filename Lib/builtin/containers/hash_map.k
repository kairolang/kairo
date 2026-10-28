/// --- The Kairo Project ------------ Lib/builtin/containers/hash_map.k --- ///
///
///   The HashMap lang item: `{K: V}`. Layouts are the ABI; bodies live in
///   std and the runtime.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

pub struct <K, V> HashMap {
    var keys:   *K
    var values: *V
    var len:    usize
    var cap:    usize

    fn HashMap(self)
}
