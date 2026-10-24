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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

module kairo::std

pub import io
