/// --- The Kairo Project ------------------- Sema/Lower/YieldLowering.k --- ///
///
///   \brief Generator lowering. EMPTY today, deliberately.
///
///   \detail
///     A generator is a C++ coroutine, and clang builds the state machine:
///     nothing here splits bodies or promotes locals. The marking is X's
///     (FunctionDecl::is_generator / has_yield, StmtTyping) and the spelling
///     is EmitIR's (`co_yield (e);`, `co_return;`), so the core path needs
///     no lowering at all.
///
///     What will live here: `yield from` delegation, the panic slot a
///     generator's promise carries across a suspension, and splicing a
///     generator's body into the TUs that call it.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

class YieldLowering {
    // TODO: implement YieldLowering
}
