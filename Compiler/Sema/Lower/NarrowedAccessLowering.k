/// --- The Kairo Project ---------------- Sema/NarrowedAccessLowering.k --- ///
///
///   \brief Rewrite narrowed nullable uses to __value().
///
///   \detail
///     For each use NullableNarrowing tagged non-null, foo.data -> 
///     foo.data.__value(). Unchecked uses were already errored upstream.
///
///   Phase: LOWER
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

class NarrowedAccessLowering {
    // TODO: implement NarrowedAccessLowering
}
