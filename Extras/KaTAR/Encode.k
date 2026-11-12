/// --- The Kairo Project -------------------- Extras/KaTAR/Encode.k ------- ///
///
///   Converts a usize to its decimal string, for the archive table.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// usize -> decimal ASCII. Avoids wstring contact for the table.
ffi "c++" import "string"

pub fn dec(n: usize) -> cxx::std::string {
    return cxx::std::to_string(n)
}
