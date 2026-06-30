/// --- The Kairo Project --------------------- Sema/ExtensionLowering.k --- ///
///
///   \brief Lower `extend` blocks to UFCS free functions.
///
///   \detail
///     extend T { fn m(self) } -> a free fn m(self: T); call sites resolve
///     x.m() to m(x) via UFCS.
///
///   Phase: LOWER
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

class ExtensionLowering {
    // TODO: implement ExtensionLowering
}
