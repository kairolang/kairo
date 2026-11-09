/// --- The Kairo Project ----------------------------- Lib/std/module.k --- ///
///
///   The std root's entry point: what `import std` binds. The root is NAMED
///   `kairo::std` -- the C++ namespace it emits into is `::kairo::std`, which
///   can never collide with C++'s own `std` (that one is `cxx::std`) -- and
///   SPELLED `std`, so source writes `import std::io`. Nothing reaches std
///   without importing it; builtin is the only prelude.
///
///   The pin and re-exports only (CONTRACT.txt 2): `module kairo::std` pins
///   this directory as the library the driver registers it as, and each file
///   here is a module of its own, reached as `std::<file>`.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

module kairo::std

/// The `std::io` module: `print`, `println`, `eprint`, `eprintln` and `flush`.
pub import io
/// The `std::env` module: the process's view of its host (`exe_path`).
pub import env
/// C and C++ character types (`c_char`, `c_wchar`, `c_char16`, `c_char8`), re-exported at
/// the std root, so they are spelled `std::c_char` and so on.
pub import ctypes::*
/// The allocation API from `std::mem` (`create`, `destroy`, `AllocatorScope`, ...),
/// re-exported at the std root.
pub import mem::*
