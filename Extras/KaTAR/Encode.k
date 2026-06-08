/// --- The Kairo Project -------------------- Extras/KaTAR/Encode.k ------- ///
///
///   Integer encoding helpers for the archive table serialization.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// usize -> decimal ASCII. Avoids wstring contact for the table.
fn dec(n: usize) -> libcxx::string {
    return libcxx::to_string(n);
}