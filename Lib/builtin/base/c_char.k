/// --- The Kairo Project -------------------- Lib/builtin/base/c_char.k --- ///
///
///   C and C++'s plain `char`, the third 8-bit character type beside `signed
///   char` (i8) and `unsigned char` (u8). Users spell it `std::c_char` (std
///   re-exports this). The CChar lang item: TypeResolve gives this alias
///   BuiltinKind::CChar, which C++ spells `char`; the `u8` below is only what
///   parses, never the type. In builtin because a lang item binds from
///   builtin; in a file of its own, not the root, so string.k (which the
///   root imports) can name it for c_str() without an import cycle.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// C and C++'s plain `char`, a character type distinct from `i8` and `u8`. Users spell it
/// `std::c_char`.
///
/// The `u8` body is only what parses; the type is the `CChar` lang item, which C++ spells `char`.
pub type __builtin_c_char = u8

/// C++'s `wchar_t`, the `CWChar` lang item. Users spell it `std::c_wchar`.
///
/// Distinct from every integer type. The `u32` body is only what parses; the type store lays it
/// out from the target (16 bits wide on Windows).
pub type __builtin_c_wchar = u32
/// C++'s `char16_t`, the `CChar16` lang item. Users spell it `std::c_char16`.
pub type __builtin_c_char16 = u16
/// C++'s `char8_t`, the `CChar8` lang item. Users spell it `std::c_char8`.
pub type __builtin_c_char8 = u8
