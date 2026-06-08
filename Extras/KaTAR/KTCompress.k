/// --- The Kairo Project ------------------ Extras/KaTAR/KTCompress.k ----- ///
///
///   Quick compressor tool to merge all files in a project into a single file
///   for easier distribution.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
///   Container layout (all bytes, UTF-8):
///
///     [data section]            raw file contents, each followed by '\n'
///     [table]                   N entries, each:
///                                 <namelen>\n<name bytes><offset>\n<length>\n
///     [trailer]                 <entry_count>\n<table_offset>\n
///
///   Reader: read trailer last two lines -> entry_count, table_offset.
///   Seek to table_offset, parse exactly entry_count entries. Filenames are
///   length-prefixed so embedded newlines are safe.
///
/// ------------------------------------------------------------------------ ///


struct TableEntry {
    var filename: libcxx::string;   // already UTF-8 bytes
    var offset:   usize;             // byte offset into data section
    var length:   usize;             // byte length of file contents
}

// wstring -> utf8 std::string. No <codecvt>, no locale streams.
fn to_utf8(src: *(libcxx::wstring)) -> libcxx::string {
    var out: libcxx::string;
    out.reserve(src->size());

    for wc in *src {
        var cp: u32 = static_cast::<u32>(wc);
        if (cp < 0x80) {
            out.push_back(static_cast::<char>(cp));
        } else if (cp < 0x800) {
            out.push_back(static_cast::<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast::<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(static_cast::<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast::<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast::<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast::<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast::<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast::<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast::<char>(0x80 | (cp & 0x3F)));
        }
    }

    return out;
}

// usize -> decimal ascii. Avoids any kairo-wstring contact for the table.
fn dec(n: usize) -> libcxx::string {
    return libcxx::to_string(n);
}

fn main(argc: i32, argv: *(*kairo::std::Legacy::char)) -> i32 {
    if argc != 3 {
        std::print("Usage: ktcompress <input_folder> <output_file>");
        return 1;
    }

    var root_path   = argv[1];
    var output_file = argv[2];

    var data_section : libcxx::string;
    var table : vec::<TableEntry>;

    for file in libcxx::filesystem::recursive_directory_iterator(root_path) {
        if file.is_regular_file() {
            // Read raw bytes. No wide stream, no locale interpretation.
            var filedata = libcxx::ifstream(file.path(), libcxx::ios::binary);
            var contents : libcxx::string = libcxx::string(
                (libcxx::istreambuf_iterator::<kairo::std::Legacy::char>(filedata)),
                libcxx::istreambuf_iterator::<kairo::std::Legacy::char>());

            var start : usize = data_section.size();   // offset BEFORE append

            var rel : libcxx::wstring =
                libcxx::filesystem::relative(file.path(), root_path).generic_wstring();

            table.push_back(TableEntry {
                filename: to_utf8(&rel),
                offset: start,
                length: contents.size(),
            });

            data_section += contents;
            data_section += r"\n";
        }
    }

    // Build the table as one UTF-8 byte string. Filenames are length-prefixed,
    // so a '\n' inside a filename can't desync the reader.
    var table_bytes : libcxx::string;
    for entry in table {
        table_bytes += dec(entry.filename.size());   // <namelen>
        table_bytes += r"\n";
        table_bytes += entry.filename;               // <name bytes> (no delimiter)
        table_bytes += dec(entry.offset);
        table_bytes += r"\n";
        table_bytes += dec(entry.length);
        table_bytes += r"\n";
    }

    var table_offset : usize = data_section.size();

    var out = libcxx::ofstream(output_file, libcxx::ios::binary);
    out << data_section;
    out << table_bytes;

    // Trailer: entry count first, then where the table begins.
    out << dec(table.size());
    out << r"\n";
    out << dec(table_offset);
    out << r"\n";

    std::print(f"Wrote {table.size()} files, data section {table_offset} bytes");
    out.flush();
    return 0;
}