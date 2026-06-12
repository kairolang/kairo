/// --- The Kairo Project ----------------- Compiler/Sema/MatchExhaustiveness.k --- ///
///
///   \brief Verify match covers all cases.
///
///   \detail
///     Per docs: plain/ADT enums need all variants or default; ints/strings
///     always need default; bool needs true+false; structs need default.
///     Expression-form match REQUIRES exhaustiveness. (Maranget usefulness algo
///     if completeness ever matters.)
///
///   Phase: CHECK
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

class MatchExhaustiveness {
    // TODO: implement MatchExhaustiveness
}
