/// --- The Kairo Project -------------------- Extras/KaTAR/TableEntry.k --- ///
///
///   Shared archive table entry type used by both KTCompress and KTDecompress.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

struct TableEntry {
    var filename: libcxx::string;   // UTF-8 bytes
    var offset:   usize;            // byte offset into data section
    var length:   usize;            // byte length of file contents
}