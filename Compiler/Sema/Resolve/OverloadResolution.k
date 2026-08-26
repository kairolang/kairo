/// --- The Kairo Project ------------ Sema/Resolve/OverloadResolution.k --- ///
///
///   \brief Pick a single callee from a deferred overload set.
///
///   \detail
///     Drains `candidate_cell` on NamedIdentExpr and ChainExpr::Step once
///     argument types are known. Ranks by conversion sequence, then by
///     constraint subsumption, then by template specialization ordering.
///     Ambiguity is an error naming every tied candidate, not a silent
///     pick. Runs after TypeInference; nothing before it may read
///     candidate_cell.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

class OverloadResolution {
    // TODO: implement OverloadResolution
}
