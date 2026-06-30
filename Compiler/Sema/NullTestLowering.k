/// --- The Kairo Project ---------------------- Sema/NullTestLowering.k --- ///
///
///   \brief Lower `x?` (condition position) to __has_value().
///
///   \detail
///     foo? -> foo.__has_value(). The narrowing decision already happened in
///     NullableNarrowing; this just emits the test.
///
///   Phase: LOWER
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

class NullTestLowering {
    // TODO: implement NullTestLowering
}
