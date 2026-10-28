/// --- The Kairo Project --------------------- Lib/builtin/num/bigint.k --- ///
///
///   The BigInt lang item. Layout only.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

pub struct BigInt   { var limbs: *u64; var len: usize; var neg: bool }
