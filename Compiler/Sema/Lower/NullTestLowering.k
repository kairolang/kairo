/// --- The Kairo Project ---------------------- Sema/NullTestLowering.k --- ///
///
///   \brief Lower `x?` (condition position) to __has_value().
///
///   \detail
///     foo? -> foo.__has_value(). The narrowing decision already happened in
///     NullableNarrowing; this just emits the test.
///
///   Phase: LOWER
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

class NullTestLowering {
    // TODO: implement NullTestLowering
}
