/// --- The Kairo Project --------------------- Lib/builtin/base/c_char.k --- ///
///
///   C and C++'s plain `char`, the third 8-bit character type beside `signed
///   char` (i8) and `unsigned char` (u8). Users spell it `std::c_char` (std
///   re-exports this). The CChar lang item: TypeResolve gives this alias
///   BuiltinKind::CChar, which C++ spells `char`; the `u8` below is only what
///   parses, never the type. In builtin because a lang item binds from
///   builtin; in a file of its own, not the root, so string.k (which the
///   root imports) can name it for c_str() without an import cycle.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

pub type __builtin_c_char = u8
