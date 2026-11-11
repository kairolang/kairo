/// --- The Kairo Project ----------------------- AST/Serialize/module.k --- ///
///
///   Marks AST/Serialize/ as a module: the binary form of one file's parsed
///   AST (Compiler/Spec/Serialization.md). Every file under it shares a
///   `prot`; what the driver and the parser use is `pub`.
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
