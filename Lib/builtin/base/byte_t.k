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

/// What `byte` is in C++: a scoped enum over u8, which is `std::byte`'s own
/// shape (no arithmetic, explicit conversions) without needing <cstddef>.
/// Kairo bypasses clang's preprocessor, so an emitted TU cannot #include
/// one; a builtin declaration the plan emits like any other can. Named
/// `Byte` because `byte` is a type keyword, not an identifier. `@open`: a
/// byte holds any of its 256 values, none of them a variant. Sema keeps
/// its own `byte` rules; only the C++ spelling points here.
@open pub enum Byte derives u8 {}
