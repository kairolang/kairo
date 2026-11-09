/// --- The Kairo Project --------------------------------- AST/module.k --- ///
///
///   Marks AST/ as a module: the syntax tree: node and kind definitions,
///   the AST context, visitors, matchers, printers and the shared fact
///   tables. Every file under it (nested directories included) shares a
///   `prot`; what other modules use is marked `pub`. No `module` pin: a pin
///   would rename every file's module path and emitted namespace.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
