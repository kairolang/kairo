/// --- The Kairo Project -------------------- Sema/Lower/IterLowering.k --- ///
///
///   \brief Lower `for x in e` to the Iter<T> protocol.
///
///   \detail
///     Iter<T> is a separate protocol from Yield<T>: a generator is
///     iterable, but not everything iterable is a generator. Resolves the
///     protocol conformance, emits the init/next/done shape, and inserts
///     the destructor for the iterator at scope exit.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

class IterLowering {
    // TODO: implement IterLowering
}
