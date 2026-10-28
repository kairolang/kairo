/// --- The Kairo Project ------------------- Lib/builtin/num/bigfloat.k --- ///
///
///   The BigFloat lang item. Layout only.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import num::bigint::*

pub struct BigFloat { var mant: BigInt; var exp: i64 }
