/// --- The Kairo Project -------------------- Extras/KaTAR/TableEntry.k --- ///
///
///   The archive table entry type shared by KTCompress and KTDecompress.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "string";

pub struct TableEntry {
    pub var filename: cxx::std::string;   // UTF-8 bytes
    pub var offset:   usize;            // byte offset into data section
    pub var length:   usize;            // byte length of file contents
}