/// --- The Kairo Project -------------------- Lib/builtin/base/byte_t.k --- ///
///
///   The Byte lang item: the C++ spelling of `byte`. The file is not
///   `byte.k` because `byte` is a keyword, and a keyword cannot be a
///   module path segment.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// The C++ spelling of the `byte` type keyword.
///
/// `@open`: a byte holds any of its 256 values and none of them is a variant. Sema keeps its own
/// `byte` rules; only the C++ spelling points here.
///
/// \note Bitwise operators (`&`, `|`, `^`, `~`, `<<`, `>>`) on `byte` are not defined yet.
@open pub enum Byte derives u8 {}
