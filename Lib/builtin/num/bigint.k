/// --- The Kairo Project --------------------- Lib/builtin/num/bigint.k --- ///
///
///   The BigInt lang item, the arbitrary-precision integer. Layout only.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// The arbitrary-precision integer lang item. Layout only: no operations are declared in
/// builtin yet.
///
/// Fields: `limbs` points at the 64-bit limbs of the magnitude, `len` counts them, and `neg`
/// is the sign flag.
pub struct BigInt   { var limbs: *u64; var len: usize; var neg: bool }
