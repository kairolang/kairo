/// --- The Kairo Project ----------------------------- Lib/std/ctypes.k --- ///
///
///   The C and C++ character types: `c_char`, `c_wchar`, `c_char16` and
///   `c_char8`. Re-exported from std's root, so they are `std::c_char` etc.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// C and C++'s plain `char`: neither `i8` (`signed char`) nor `u8`
/// (`unsigned char`), and signed or not as the target's C is. A C string is
/// `*const c_char`, which is `const char*` exactly, and a C `char` imports
/// as this. A character, not a number: `as` converts it to and from the
/// integers, and a literal takes it only in 0 through 127.
pub type c_char = __builtin_c_char

/// C++'s `wchar_t`: 32 bits on most targets and 16 on Windows, signed or
/// not as the target's C++ says. A C++ `wchar_t` imports as this, so
/// `const wchar_t*` is `*const c_wchar` and `f(wchar_t)` is an overload
/// apart from `f(int)`. Like `c_char`, a character, not a number: `as`
/// converts it to and from the integers, and a literal takes it only in
/// 0 through 0xFFFF, which fits it on every target.
pub type c_wchar = __builtin_c_wchar

/// C++'s `char16_t`: a UTF-16 code unit, 16 bits, unsigned. `as` to and
/// from the integers; a literal takes it in 0 through 0xFFFF.
pub type c_char16 = __builtin_c_char16

/// C++'s `char8_t`: a UTF-8 code unit, 8 bits, unsigned, a type apart from
/// `char` and `unsigned char` (`u8`). `as` to and from the integers; a
/// literal takes it in 0 through 255.
pub type c_char8 = __builtin_c_char8
