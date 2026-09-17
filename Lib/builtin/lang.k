/// --- The Kairo Project --------------------------- Lib/builtin/lang.k --- ///
///
///   Non-container lang items: what `..`, `<=>`, `spawn`, `yield`, `T?` and
///   the panic machinery desugar through. Declarations only.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import string::*

pub struct <T> Range {
    var begin:     T
    var end:       T
    var inclusive: bool
}

pub enum Ordering derives i8 {
    Less    = -1,
    Equal   = 0,
    Greater = 1,
}

pub struct <T> Future  { var state: *void }
pub struct <T> Yield   { var state: *void }
pub struct <T> Null    { var value: T; var has: bool }
pub struct <T> Panic   { var value: T }

pub struct BigInt   { var limbs: *u64; var len: usize; var neg: bool }
pub struct BigFloat { var mant: BigInt; var exp: i64 }

pub struct PanicRaise { var payload: *void }
pub struct PanicCatch { var payload: *void }
pub struct AssertFail { var message: string }
