/// --- The Kairo Project ----------------------------- Support/Limits.k --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

///
/// \file Limits.k
/// \brief integer limits for every builtin width, spelled so stage 0 gets
///        them right.
///
/// \details
/// most of these are ordinary literals and exist only so the compiler sources
/// have one place to reach for a bound. three of them cannot be written as the
/// obvious literal at all, because the stage-0 compiler that builds this file
/// mis-evaluates the expression. use the constants; do not re-derive them.
///
/// ### trap 1: the [2^31, 2^32) literal band
///
/// stage 0 types an integer literal needing exactly 32 bits as *signed* 32-bit
/// rather than promoting it, so `0xFFFFFFFF` evaluates to `-1`. silently; there
/// is no diagnostic. two things break as a result:
///
///   - a comparison against a `u64`/`usize` never fires, because the `-1`
///     widens to `0xFFFFFFFFFFFFFFFF`. `if v > 0xFFFFFFFF` is dead code.
///   - a mask becomes a no-op. `val & 0xFFFFFFFF` returns `val` unchanged
///     instead of its low 32 bits, for the same reason.
///
/// only 64-bit operands are affected. a `u32`-typed operand is correct, since
/// both sides land on the same 32-bit pattern, which is why `U32_MAX` below is
/// declared `u32` and widens correctly into `u64` expressions.
///
/// integer suffixes are not a way out; stage 0 rejects `0xFFFFFFFFu64` with
/// "invalid suffix 'u64' on integer constant". the bound has to be built from
/// small literals, which is what `U32_MAX` does.
///
/// ### trap 2: unary minus binds looser than a binary operator when folded
///
/// stage 0 folds `-127 - 1` as `-(127 - 1)`, i.e. `-126`, and `-10 + 5` as
/// `-(10 + 5)`, i.e. `-15`. the wrong value propagates into runtime code with
/// no diagnostic. the idiomatic way to spell a signed minimum, `-MAX - 1`, is
/// therefore WRONG here; parenthesise the unary operand (`(-MAX) - 1`) or use
/// a direct literal. the direct literals below (`-128`, `-2147483648`,
/// `-9223372036854775808`) were each verified to evaluate correctly.
///
/// \note remove the workarounds once stage 0 fixes both; until then, never
///       spell a 32-bit bound in a 64-bit context, and never write `-X - 1`.
///

// --- unsigned maxima --------------------------------------------------------

const U8_MAX:  u8  = 255;;
const U16_MAX: u16 = 65535;;

/// \brief largest value representable in 32 bits.
/// \details built from small literals; see trap 1. `u32`-typed on purpose, so
///          it widens correctly for both range checks (`v > U32_MAX`) and
///          low-32 masks (`v & U32_MAX`) on 64-bit operands.
const U32_MAX: u32 = static_cast::<u32>((static_cast::<u64>(1) << 32) - 1);;

const U64_MAX: u64 = 0xFFFFFFFFFFFFFFFF;;

// --- unsigned minima --------------------------------------------------------
// present for symmetry, so generic code can name a lower bound per width.

const U8_MIN:  u8  = 0;;
const U16_MIN: u16 = 0;;
const U32_MIN: u32 = 0;;
const U64_MIN: u64 = 0;;

// --- signed maxima ----------------------------------------------------------

const I8_MAX:  i8  = 127;;
const I16_MAX: i16 = 32767;;
const I32_MAX: i32 = 2147483647;;
const I64_MAX: i64 = 0x7FFFFFFFFFFFFFFF;;

// --- signed minima ----------------------------------------------------------
// direct literals, NOT `-MAX - 1`; see trap 2.

const I8_MIN:  i8  = -128;;
const I16_MIN: i16 = -32768;;
const I32_MIN: i32 = -2147483648;;
const I64_MIN: i64 = -9223372036854775808;;

// --- pointer-width ----------------------------------------------------------
// derived rather than assumed, so a 32-bit target stays correct.

const USIZE_MIN: usize = 0;;
const USIZE_MAX: usize = ~usize(0);;

/// \note the trailing `- 1` needs the unary minus parenthesised; see trap 2.
const ISIZE_MAX: isize = static_cast::<isize>((~usize(0)) >> 1);;
const ISIZE_MIN: isize = (-static_cast::<isize>((~usize(0)) >> 1)) - 1;;
