/// --- The Kairo Project ------------------ Extras/KaTAR/KTCompress.k ----- ///
///
///   Archive writer - packs a directory tree into a single KTAR file.
///
///   Container layout (all bytes, UTF-8):
///
///     [data section]   raw file contents, each followed by '\n'
///     [table]          N entries, each:
///                        <namelen>\n<name bytes><offset>\n<length>\n
///     [trailer]        <entry_count>\n<table_offset>\n
///
///   Reader: read trailer last two lines -> entry_count, table_offset.
///   Seek to table_offset, parse exactly entry_count entries. Filenames
///   are length-prefixed so embedded newlines are safe.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import TableEntry::*;
import UTF8::*;
import Encode::*;
import std::c_char
import std::io
ffi "c++" import "string";
ffi "c++" import "vector";
ffi "c++" import "filesystem";
ffi "c++" import "fstream";
ffi "c++" import "ios";
ffi "c++" import "iterator";

pub fn main(argc: i32, argv: unsafe *(unsafe *c_char)) -> i32 {
    if argc != 3 {
        io::println("Usage: ktcompress <input_folder> <output_file>");
        return 1;
    }

    var unsafe *root_path   = argv[1];
    var unsafe *output_file = argv[2];

    var data_section : cxx::std::string;
    var table : cxx::std::vector<TableEntry>;

    for file in cxx::std::filesystem::recursive_directory_iterator(cxx::std::filesystem::path(root_path)) {
        if file.is_regular_file() {
            var filedata = cxx::std::ifstream(file.path(), cxx::std::ios::binary);
            var contents : cxx::std::string = cxx::std::string(
                cxx::std::istreambuf_iterator<c_char>(&filedata),
                cxx::std::istreambuf_iterator<c_char>());

            var start : usize = data_section.size();

            var rel : cxx::std::wstring =
                cxx::std::filesystem::relative(file.path(), cxx::std::filesystem::path(root_path)).generic_wstring();

            table.push_back(TableEntry {
                filename: to_utf8(unsafe &rel),
                offset:   start,
                length:   contents.size(),
            });

            data_section += contents;
            data_section.push_back(('\n' as u8) as c_char);
        }
    }

    // Build table bytes. Filenames are length-prefixed so '\n' inside a
    // filename cannot desync the reader.
    var table_bytes : cxx::std::string;
    for entry in table {
        table_bytes += dec(entry.filename.size());
        table_bytes.push_back(('\n' as u8) as c_char);
        table_bytes += entry.filename;
        table_bytes += dec(entry.offset);
        table_bytes.push_back(('\n' as u8) as c_char);
        table_bytes += dec(entry.length);
        table_bytes.push_back(('\n' as u8) as c_char);
    }

    var table_offset : usize = data_section.size();

    var out = cxx::std::ofstream(output_file, cxx::std::ios::binary);
    out << data_section;
    out << table_bytes;

    // Trailer: entry count first, then where the table begins.
    out << dec(table.size());
    out << "\n";
    out << dec(table_offset);
    out << "\n";

    io::println(f"Wrote {table.size()} files, data section {table_offset} bytes");
    out.flush();
    return 0;
}