/// --- The Kairo Project ----------------------------- Support/Limits.k --- ///
///
///   Integer limits for every builtin width, under the compiler's names.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

///
/// \file Limits.k
/// \brief integer limits for every builtin width, under one set of names.
///
/// \details
/// each constant is the language limit (`u32::MAX`, `i64::MIN`, ...) with the
/// type it has always had here; the names predate those limits and the
/// compiler sources still use them. `U32_MAX` is `u32`, so it widens into a
/// `u64` expression for a range check (`v > U32_MAX`) or a low-32 mask
/// (`v & U32_MAX`).
///

/// # unsigned maxima

pub
const U8_MAX: u8 = u8::MAX
pub
const U16_MAX: u16 = u16::MAX
pub
const U32_MAX: u32 = u32::MAX
pub
const U64_MAX: u64 = u64::MAX

/// # unsigned minima
/// present for symmetry, so generic code can name a lower bound per width.

pub
const U8_MIN: u8 = 0
pub
const U16_MIN: u16 = 0
pub
const U32_MIN: u32 = 0
pub
const U64_MIN: u64 = 0

/// # signed maxima

pub
const I8_MAX: i8 = i8::MAX
pub
const I16_MAX: i16 = i16::MAX
pub
const I32_MAX: i32 = i32::MAX
pub
const I64_MAX: i64 = i64::MAX

/// # signed minima

pub
const I8_MIN: i8 = i8::MIN
pub
const I16_MIN: i16 = i16::MIN
pub
const I32_MIN: i32 = i32::MIN
pub
const I64_MIN: i64 = i64::MIN

/// # Pointer width
/// None here: `usize::MAX`, `isize::MIN` and `isize::MAX` are language limits that take
/// the target's width.
