/// --- The Kairo Project ------------------------------ Native/module.k --- ///
///
///   Marks Native/ as a module: the base layer under the compiler
///   (character tables, arenas, threading, timing and progress, the clang
///   queries Sema and Codegen make). The `.hh` headers beside it are the
///   C++ part of the layer, what Kairo cannot spell, ffi-imported as
///   `Native/X.hh`.
///   Every file under it shares a `prot`; what other modules use is `pub`.
///
///   No `module` pin: a pin would rename every file's module path and
///   emitted namespace.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
