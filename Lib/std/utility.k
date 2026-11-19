/// --- The Kairo Project ---------------------------- Lib/std/utility.k --- ///
///
///   Explicit value transfer: `move` and `copy`, re-exported at the std
///   root as `std::move` and `std::copy`.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

pub import builtin::base::copy::{
    copy,
    move,
}
