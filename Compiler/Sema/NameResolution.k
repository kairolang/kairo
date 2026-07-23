/// --- The Kairo Project ------------------------ Sema/NameResolution.k --- ///
///
///   \brief Bind every identifier use to its declaration.
///
///   \detail
///     Walks scopes + hoisted table, attaches resolved_decl to each name use.
///     ANNOTATES nodes (does not just rewrite) so jump-to-def / completion can
///     query resolution later. Foundation for everything downstream most
///     passes assume names are resolved.
///
///   Phase: RESOLVE
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

class NameResolution {
    // TODO: implement NameResolution
}
