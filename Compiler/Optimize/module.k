/// --- The Kairo Project ---------------------------- Optimize/module.k --- ///
///
///   Marks Optimize/ as a module: the optimisation passes, kept apart from
///   the passes that give a program its meaning. A pass here only makes a
///   program faster or smaller; the program means the same without it.
///   LLVM/ holds the passes that run on a TU's IR inside LLVM's pipeline,
///   and the C++ bridge that puts them there.
///   Every file under it (nested directories included) shares a `prot`;
///   what other modules use is marked `pub`.
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
