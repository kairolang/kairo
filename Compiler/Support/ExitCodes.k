/// --- The Kairo Project -------------------------- Support/ExitCodes.k --- ///
///
///   The process exit statuses the kairo and kcc drivers return, one place.
///   Scripts and build systems branch on these numbers, so they are part of
///   the command-line interface (Compiler/Spec/Driver.md): a change here is
///   a change for every caller.
///
///   Not here: the sysroot statuses (2 refusal, 3 build failure) are
///   Linker/Sysroot/Outcome.k's, which the driver passes through unchanged,
///   and the emitted program's abort status is a runtime ABI value
///   (AST/LangItems.k).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// Success: no error anywhere in the batch (warnings alone are success), or
/// an identity query (--help, --version, --print-*) that answered.
pub
eval EXIT_OK: i32 = 0

/// Any error: a diagnostic of error severity, a bad flag, an unwritable
/// output, an info query that could not answer.
pub
eval EXIT_FAILURE: i32 = 1
