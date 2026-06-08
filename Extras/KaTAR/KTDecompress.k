/// --- The Kairo Project -------------- Extras/KaTAR/KTDecompress.k ------- ///
///
///   Archive extractor - reverses KTCompress.
///   Reads the trailer, walks the table, writes each file to disk.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import TableEntry::*;

fn main(argc: i32, argv: *(*kairo::std::Legacy::char)) -> i32 {
    if argc != 3 {
        std::print("Usage: ktextract <archive_file> <output_folder>");
        return 1;
    }

    var archive_path = argv[1];
    var output_root  = argv[2];

    var f = libcxx::ifstream(archive_path, libcxx::ios::binary | libcxx::ios::ate);
    if !f.is_open() {
        std::print(f"Error: cannot open '{archive_path}' ");
        return 1;
    }

    var file_size: usize = static_cast::<usize>(f.tellg());

    // Scan backwards for the third newline to find the trailer start.
    var newline_count: i32 = 0;
    var trailer_start: i64 = static_cast::<i64>(file_size) - 1;

    while trailer_start >= 0 {
        f.seekg(trailer_start);
        var ch: char = static_cast::<char>(f.get());
        if ch == '\n' {
            newline_count += 1;
            if newline_count == 3 {
                break;
            }
        }
        trailer_start -= 1;
    }

    f.seekg(trailer_start + 1);

    var entry_count_str: libcxx::string;
    libcxx::getline(f, entry_count_str);
    var entry_count: usize = libcxx::stoull(entry_count_str);

    var table_offset_str: libcxx::string;
    libcxx::getline(f, table_offset_str);
    var table_offset: usize = libcxx::stoull(table_offset_str);

    f.seekg(static_cast::<i64>(table_offset));

    var table: vec::<TableEntry>;
    table.reserve(entry_count);

    for (var i : usize = 0; i < usize(entry_count); i += 1) {
        var namelen_str: libcxx::string;
        libcxx::getline(f, namelen_str);
        var namelen: usize = libcxx::stoull(namelen_str);

        var name: libcxx::string;
        name.resize(namelen);
        f.read(name.data(), static_cast::<i64>(namelen));

        var offset_str: libcxx::string;
        libcxx::getline(f, offset_str);
        var offset: usize = libcxx::stoull(offset_str);

        var length_str: libcxx::string;
        libcxx::getline(f, length_str);
        var length: usize = libcxx::stoull(length_str);

        table.push_back(TableEntry {
            filename: name,
            offset:   offset,
            length:   length,
        });
    }

    var output_dir = libcxx::filesystem::path(output_root);
    libcxx::filesystem::create_directories(output_dir);

    for entry in table {
        var dest = output_dir / libcxx::filesystem::path(entry.filename);
        libcxx::filesystem::create_directories(dest.parent_path());

        var contents: libcxx::string;
        contents.resize(entry.length);

        f.seekg(static_cast::<i64>(entry.offset));
        if !f.read(contents.data(), static_cast::<i64>(entry.length)) {
            std::print(f"Error: failed to read data for '{entry.filename}' ");
            return 1;
        }

        var out = libcxx::ofstream(dest, libcxx::ios::binary);
        if !out.is_open() {
            std::print(f"Error: cannot create '{dest.string()}' ");
            return 1;
        }
        out.write(contents.data(), static_cast::<i64>(entry.length));
        out.flush();

        std::print(f"  extracted: {entry.filename} ({entry.length} bytes) ");
    }

    std::print(f"{entry_count} files written to {output_root}.");
    return 0;
}