/// --- The Kairo Project -------------------------------- Sema/module.k --- ///
///
///   Marks Sema/ as a module: semantic analysis: name/type resolution,
///   checks, verification, expansion, foreign decls and lowering. Every
///   file under it (nested directories included) shares a `prot`; what
///   other modules use is marked `pub`. No `module` pin: a pin would rename
///   every file's module path and emitted namespace.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
