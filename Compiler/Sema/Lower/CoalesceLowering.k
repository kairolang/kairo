/// --- The Kairo Project ---------------------- Sema/CoalesceLowering.k --- ///
///
///   \brief Lower `a ?? b` to a guarded select.
///
///   \detail
///     a ?? b -> if a.__has_value() { a.__value() } else { b }. Result is the
///     non-null underlying type (strips the ?). Prefer select/cmov shape where
///     b is a value not control flow.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

class CoalesceLowering {
    // TODO: implement CoalesceLowering
}
