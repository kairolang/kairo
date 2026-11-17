/// --- The Kairo Project ------------------- Lib/builtin/num/bigfloat.k --- ///
///
///   The BigFloat lang item, the arbitrary-precision float. Layout only.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import num::bigint::*

/// The arbitrary-precision float lang item. Layout only: no operations are declared in
/// builtin yet.
///
/// Fields: `mant` is the mantissa (a BigInt) and `exp` is the exponent.
pub struct BigFloat { var mant: BigInt; var exp: i64 }
