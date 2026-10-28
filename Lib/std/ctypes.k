/// --- The Kairo Project ----------------------------- Lib/std/ctypes.k --- ///
///
///   Types for talking to C and C++ that Kairo's own primitives do not
///   cover. Re-exported from std's root, so they are `std::c_char` and so on.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// C and C++'s plain `char`: neither `i8` (`signed char`) nor `u8`
/// (`unsigned char`), and signed or not as the target's C is. A C string is
/// `*const c_char`, which is `const char*` exactly, and a C `char` imports
/// as this. A character, not a number: `as` converts it to and from the
/// integers, and a literal takes it only in 0 through 127.
pub type c_char = __builtin_c_char
