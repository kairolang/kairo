/// --- The Kairo Project -------------- Extras/KaTAR/KTDecompress.k ------- ///
///
///   Archive extractor, the reverse of KTCompress: reads the trailer and the
///   table, refuses unsafe names, and writes each file to disk.
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
import std::c_char
import std::io
ffi "c++" import "fstream";
ffi "c++" import "ios";
ffi "c++" import "string";
ffi "c++" import "vector";
ffi "c++" import "filesystem";
ffi "c++" import "system_error";

// The f-string formatter knows Kairo strings, not a foreign std::string or a
// C string: given one it prints the type and address. Every name and
// path reaches a message through these.
fn text(const s: cxx::std::string) -> string {
    return string(unsafe ((s.data() as unsafe *const u8) as *const u8), s.size());
}

fn ctext(p: unsafe *c_char) -> string {
    return string(unsafe ((p as unsafe *const u8) as *const u8));
}

// An archive is untrusted input and the names in it are joined onto the
// destination, so a name that is absolute, climbs with '..', or carries a
// Windows root would write wherever the archive author chooses. Names are
// refused, never rewritten: a sanitized name would extract to a path the
// archive did not ask for and hide that the archive is hostile. Returns the
// reason a name is unsafe, or an empty string if it is fine.
fn unsafe_name_reason(name: cxx::std::string) -> cxx::std::string {
    var n: usize = name.size();
    if n == 0 {
        return cxx::std::string("empty name");
    }

    // Both separators are folded together up front because the archive may
    // have been built on a host whose separator differs from the extractor's;
    // '\' is an ordinary filename byte on POSIX but a separator on Windows,
    // so the only name safe everywhere is one safe under both readings.
    var comp_start: usize = 0;
    var i: usize = 0;
    while i < n {
        var c: u8 = (name[i] as u8);
        if c == (0 as u8) {
            return cxx::std::string("name contains a NUL byte");
        }
        i += 1;
    }

    // A leading separator covers '/x', '\x' and the UNC form '\\server\x'.
    var first: u8 = (name[0] as u8);
    if first == ('/' as u8) || first == ('\\' as u8) {
        return cxx::std::string("absolute path");
    }

    // 'C:x' is drive-relative, not absolute, so a root check alone misses it
    // yet on Windows it resolves against that drive's current directory.
    if n >= 2 {
        var d: u8 = (name[0] as u8);
        var colon: u8 = (name[1] as u8);
        var is_alpha: bool = (d >= ('a' as u8) && d <= ('z' as u8)) || (d >= ('A' as u8) && d <= ('Z' as u8));
        if is_alpha && colon == (':' as u8) {
            return cxx::std::string("drive letter prefix");
        }
    }

    i = 0;
    while i <= n {
        var at_end: bool = (i == n);
        var sep: bool = at_end;
        if (!at_end) {
            var ch: u8 = (name[i] as u8);
            sep = (ch == ('/' as u8)) || (ch == ('\\' as u8));
        }
        if sep {
            var len: usize = i - comp_start;
            if len == 0 {
                return cxx::std::string("empty path component");
            }
            if len == 2 && (name[comp_start] as u8) == ('.' as u8) && (name[comp_start + 1] as u8) == ('.' as u8) {
                return cxx::std::string("'..' component");
            }
            comp_start = i + 1;
        }
        i += 1;
    }
    return cxx::std::string("");
}

// Filesystem-level confinement, run per entry right before anything is
// created. The name check is lexical and cannot see a symlink that already
// exists in the destination (a previous extraction, or a hostile pre-populated
// folder), and writing through one lands outside the root. Returns the reason
// the target is unsafe, or an empty string if it stays under the root.
fn escape_reason(root: cxx::std::filesystem::path, dest: cxx::std::filesystem::path) -> cxx::std::string {
    var ec: cxx::std::error_code;
    var root_c = cxx::std::filesystem::weakly_canonical(root, &ec);
    if ec.value() != 0 {
        return cxx::std::string("cannot resolve destination");
    }
    var dest_c = cxx::std::filesystem::weakly_canonical(dest, &ec);
    if ec.value() != 0 {
        return cxx::std::string("cannot resolve target");
    }

    var rel = dest_c.lexically_relative(root_c);
    if rel.empty() {
        return cxx::std::string("resolves outside the destination");
    }
    var dotdot = cxx::std::filesystem::path(cxx::std::string(".."));
    var cur = root_c;
    for part in rel {
        if part == dotdot {
            return cxx::std::string("resolves outside the destination");
        }
        cur /= part;
        // weakly_canonical treats a dangling symlink as a missing path, so a
        // link to a not-yet-existing outside directory passes the prefix test
        // and create_directories would then create it; look at each link
        // itself rather than where it points.
        if cxx::std::filesystem::is_symlink(cur, &ec) {
            return cxx::std::string("path passes through a symbolic link");
        }
    }
    return cxx::std::string("");
}

pub fn main(argc: i32, argv: unsafe *(unsafe *c_char)) -> i32 {
    if argc != 3 {
        io::println("Usage: ktextract <archive_file> <output_folder>");
        return 1;
    }

    var archive_path = argv[1];
    var output_root  = argv[2];

    var f = cxx::std::ifstream(archive_path, cxx::std::ios::binary | cxx::std::ios::ate);
    if !f.is_open() {
        io::println(f"Error: cannot open '{ctext(archive_path)}'");
        return 1;
    }

    var file_size: usize = (cxx::std::filesystem::file_size(cxx::std::filesystem::path(archive_path)) as usize);

    // Scan backwards for the third newline to find the trailer start.
    var newline_count: i32 = 0;
    var trailer_start: i64 = (file_size as i64) - 1;

    while trailer_start >= 0 {
        f.seekg(cxx::std::streampos(trailer_start));
        var ch: u8 = (f.get() as u8);
        if ch == ('\n' as u8) {
            newline_count += 1;
            if newline_count == 3 {
                break;
            }
        }
        trailer_start -= 1;
    }

    f.seekg(cxx::std::streampos(trailer_start + 1));

    var entry_count_str: cxx::std::string;
    cxx::std::getline(&f, &entry_count_str);
    var entry_count: usize = (cxx::std::stoull(entry_count_str) as usize);

    var table_offset_str: cxx::std::string;
    cxx::std::getline(&f, &table_offset_str);
    var table_offset: usize = (cxx::std::stoull(table_offset_str) as usize);

    f.seekg(cxx::std::streampos(table_offset as i64));

    var table: cxx::std::vector<TableEntry>;
    table.reserve(entry_count);

    for var i : usize = 0; i < (entry_count as usize); i += 1 {
        var namelen_str: cxx::std::string;
        cxx::std::getline(&f, &namelen_str);
        var namelen: usize = (cxx::std::stoull(namelen_str) as usize);

        var name: cxx::std::string;
        name.resize(namelen);
        f.read(name.data(), namelen as isize);

        var offset_str: cxx::std::string;
        cxx::std::getline(&f, &offset_str);
        var offset: usize = (cxx::std::stoull(offset_str) as usize);

        var length_str: cxx::std::string;
        cxx::std::getline(&f, &length_str);
        var length: usize = (cxx::std::stoull(length_str) as usize);

        table.push_back(TableEntry {
            filename: name,
            offset:   offset,
            length:   length,
        });
    }

    // Validate every name before touching the disk so a hostile archive is
    // refused whole instead of leaving its earlier entries half-extracted.
    // Same stop-at-first-error convention as the rest of this tool.
    for entry in table {
        var why = unsafe_name_reason(entry.filename);
        if why.size() != 0 {
            io::println(f"Error: refusing unsafe entry '{text(entry.filename)}': {text(why)}");
            return 1;
        }
        // A forged table can point past the data section; resize() below
        // would then allocate whatever length the archive claims.
        if entry.offset > file_size || entry.length > file_size - entry.offset {
            io::println(f"Error: entry '{text(entry.filename)}' lies outside the archive");
            return 1;
        }
    }

    var output_dir = cxx::std::filesystem::path(output_root);
    cxx::std::filesystem::create_directories(output_dir);

    for entry in table {
        var dest = output_dir / cxx::std::filesystem::path(entry.filename);

        var escape = escape_reason(output_dir, dest);
        if escape.size() != 0 {
            io::println(f"Error: refusing unsafe entry '{text(entry.filename)}': {text(escape)}");
            return 1;
        }
        cxx::std::filesystem::create_directories(dest.parent_path());
        // Re-check after the directories exist: a directory just created or
        // raced into place must still resolve under the root.
        escape = escape_reason(output_dir, dest);
        if escape.size() != 0 {
            io::println(f"Error: refusing unsafe entry '{text(entry.filename)}': {text(escape)}");
            return 1;
        }

        var contents: cxx::std::string;
        contents.resize(entry.length);

        f.seekg(cxx::std::streampos(entry.offset as i64));
        if !f.read(contents.data(), entry.length as isize) {
            io::println(f"Error: failed to read data for '{text(entry.filename)}'");
            return 1;
        }

        var out = cxx::std::ofstream(dest, cxx::std::ios::binary);
        if !out.is_open() {
            io::println(f"Error: cannot create '{text(dest.string())}'");
            return 1;
        }
        out.write(contents.data(), entry.length as isize);
        out.flush();

        io::println(f"  extracted: {text(entry.filename)} ({entry.length} bytes) ");
    }

    io::println(f"{entry_count} files written to {ctext(output_root)}.");
    return 0;
}