/// --- The Kairo Project ------------------------ Sema/MacroExpansion.k --- ///
///
///   \brief Expand macros and macro-like intrinsics.
///
///   \detail
///     Not unwrap!(): it is a parser intrinsic (UnwrapExpr) that
///     CoalesceLowering expands, and it aborts rather than panics, so the
///     effect checker never sees it (NULLABLE.md 2.6). Also crash!,
///     label!/jump!, user macros.
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

class MacroExpansion {
    // TODO: implement MacroExpansion
}
