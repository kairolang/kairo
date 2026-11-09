/// --- The Kairo Project ------------------------------ Driver/module.k --- ///
///
///   Marks Driver/ as a module: every file under it shares a `prot`, which
///   is what lets CompilerInstance live in several files. The class and its
///   fields are in CompilerInstance.k; each Compiler*.k beside it is one
///   concern's `extend CompilerInstance { }`, reaching the members it needs
///   as `prot` (module-wide) rather than `pub`. No `module` pin: a pin would
///   name the directory as a library and move every Driver file's module
///   path and emitted namespace.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
