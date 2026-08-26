/// --- The Kairo Project ------------------- Sema/Resolve/AccessCheck.k --- ///
///
///   \brief Enforce pub/priv/prot visibility on every resolved reference.
///
///   \detail
///     Runs after name resolution so it checks what was actually chosen,
///     not what was visible. Class and struct members default to public.
///     Reports at the use site with a note at the declaration.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

class AccessCheck {
    // TODO: implement AccessCheck
}
