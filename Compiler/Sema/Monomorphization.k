/// --- The Kairo Project ---------------------- Sema/Monomorphization.k --- ///
///
///   \brief Instantiate concrete versions of generic decls.
///
///   \detail
///     Vec<T> -> Vec<i32> per use. Stamps out one instance per type-arg set.
///     Checks lifecycle constraints (copy/move/non-transfer) at instantiation
///     per ClassLifecyclePass rules body op vs T's capability.
///
///   Phase: CHECK
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

class Monomorphization {
    // TODO: implement Monomorphization
}
