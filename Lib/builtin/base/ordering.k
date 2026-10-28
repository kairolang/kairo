/// --- The Kairo Project ------------------ Lib/builtin/base/ordering.k --- ///
///
///   The Ordering lang item: what a three-way comparison answers.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

pub enum Ordering derives i8 {
    Less    = -1,
    Equal   = 0,
    Greater = 1,
}
