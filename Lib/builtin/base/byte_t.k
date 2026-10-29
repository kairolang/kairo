/// --- The Kairo Project -------------------- Lib/builtin/base/byte_t.k --- ///
///
///   The Byte lang item: the C++ spelling of `byte`. The file is not
///   `byte.k` because `byte` is a keyword, and a keyword cannot be a
///   module path segment.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// Named `Byte` because its the conical spelling to `byte` the type keyword.
/// `@open`: a byte holds any of its 256 values, none of them a variant.
/// Sema keeps its own `byte` rules; only the C++ spelling points here.
@open pub enum Byte derives u8 {}
