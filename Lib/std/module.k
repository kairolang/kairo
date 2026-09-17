/// --- The Kairo Project ----------------------------- Lib/std/module.k --- ///
///
///   The std root's entry point. Its module path is `kairo::std`, so bare
///   `std` in Kairo source is the TU-local prelude alias for it and the C++
///   namespace it emits into is `::kairo::std` -- which can never collide
///   with C++'s own `std` (that one is spelled `cxx::std`).
///
///   Deliberately almost empty. `print` exists so the root can be tested
///   end to end -- resolution, module path, and emitted spelling -- before
///   there is a library to test with. CONTRACT.txt 2 says module.k only
///   re-exports; that holds again the moment there is a second file here.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// Emits as `::kairo::std::print`. Takes i32 rather than `string` on purpose:
/// no builtin lang item is involved, so a failure here is a root-naming
/// failure and nothing else.
pub fn print(value: i32) -> void { }
