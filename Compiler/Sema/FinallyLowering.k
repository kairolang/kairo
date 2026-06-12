/// --- The Kairo Project ----------------- Compiler/Sema/FinallyLowering.k --- ///
///
///   \brief Lower `finally` to a NON_TRANSFER RAII guard holding a lambda.
///
///   \detail
///     finally { body } -> a stack-only scope-guard whose op delete runs the
///     lambda body. Multiple finallys -> reverse declaration order (LIFO),
///     which the RAII destructor ordering gives for free. SYNTHESIZES a closure.
///
///   Phase: LOWER
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

class FinallyLowering {
    // TODO: implement FinallyLowering
}
