/// --- The Kairo Project ------------------ Extras/KaTAR/KTCompress.k ----- ///
/// 
///   Quick compressor tool to merge all files in a project into a single file for easier distribution.
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
    var filename: string;
    var offset: usize;
    var length: usize;
}

fn main(argc: i32, argv: *(*kairo::std::Legacy::char)) -> i32 {
    inline "c++" {
        ::setlocale(LC_ALL, "");
        // (void)::wcslen(WIDE_STR(""));
    }

    libcxx::use_facet::<libcxx::ctype::<char>>(libcxx::locale());
    libcxx::use_facet::<libcxx::num_put::<std::Legacy::char>>(libcxx::locale());
    libcxx::use_facet::<libcxx::num_get::<std::Legacy::char>>(libcxx::locale());

    { // Force narrow char locale facets used by stringstream/to_string
        var oss: libcxx::ostringstream;
        oss << static_cast::<usize>(1) << 1.0;
        oss.str();
    }

    if argc != 3 {
        std::print("Usage: ktcompress <input_folder> <output_file>");
        return 1;
    }

    var root_path = argv[1];
    var output_file = argv[2];

    var OPbuffer : string = "";
    var offset : usize = 0;
    var table : vec::<TableEntry>;

    for file in libcxx::filesystem::recursive_directory_iterator(root_path) {
        if file.is_regular_file() { 
            var filedata = libcxx::wifstream(file.path());
            var contents = string(libcxx::string((libcxx::istreambuf_iterator::<char>(filedata)),
                         libcxx::istreambuf_iterator::<char>()).c_str());
            //enter data as [filename] /n contents /n into OPbuffer, and add an entry to the table with filename, offset, and length
            offset += contents.length() + 1; // +1 for the newline character
            table.push_back(TableEntry {
                filename: libcxx::filesystem::relative(file.path(),root_path).generic_wstring(),
                offset: offset,
                length: contents.length(),
            });
            OPbuffer += contents + "\n";
        }
    }

    var outputstream = libcxx::wofstream(output_file);

    
    var table_offset = OPbuffer.length();
    outputstream << OPbuffer.raw_string() ;
    for entry in table {
        outputstream << f"{entry.filename}\n{entry.offset}\n{entry.length}\n".raw_string();
    }   
    outputstream << f"{table_offset}\n".raw_string();


    std::print(f"Final buffer length: {OPbuffer.length()}");
    outputstream.flush();


    libcxx::this_thread::sleep_for(libcxx::chrono::seconds(2)); // Ensure all output is flushed before program exits
    return 0;
}


