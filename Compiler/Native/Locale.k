/// --- The Kairo Project ----------------------------- Native/Locale.k --- ///
///
///   Process locale setup for the driver: the environment picks the
///   language, the compiler picks the encoding.
///
///   Every byte the compiler writes is UTF-8 (sources are validated as such,
///   diagnostics and dumps are built from them), but std::print goes out
///   through wprintf, which re-encodes each wide char with LC_CTYPE. Under
///   the "C" locale -- a scrubbed environment: lit, cron, a container with no
///   LANG -- the first non-ASCII code point hits EILSEQ and the REST OF THAT
///   PRINT CALL is dropped, so a --print-ast dump lost a whole translation
///   unit at its first U+FFFD and the next unit's lines took its place.
///
///   LC_ALL, LC_CTYPE and CODESET are macros, so they come from Shims.hh as
///   named values; langinfo.h does not exist on Windows, which gets the same
///   treatment through UCRT's ".UTF-8" codepage suffix.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Shims.hh" // lc_all, lc_ctype, langinfo_codeset
ffi "c++" import "Native/Win32.hh" // console_utf8
ffi "c++" import "clocale"
ffi "c++" import "cstring"
ffi "c++" import "cwchar"

import std::{
    c_char,
    c_wchar,
}

/// setlocale(LC_ALL, "") from the environment, then force LC_CTYPE to a UTF-8
/// codeset if that did not give one. LC_CTYPE only: the encoding, not the
/// numeric or message formats the user chose. Also touches the wide-string
/// machinery once on the calling thread: on Linux it resolves lazily and
/// segfaults if first called from a worker with a shallow stack.
///
/// On Windows also sets the console's input and output code pages to UTF-8,
/// so the UTF-8 bytes the print family writes verbatim render as text. A
/// Kairo main has no hook that runs before it, so each driver's init calls
/// this before anything is printed.
pub fn init_process_locale() {
    eval if defined!(_WIN32) {
        kairo::win32::console_utf8()
    }

    const got = cxx::std::setlocale(kairo::lc_all, "".c_str())
    eval if defined!(_WIN32) {
        // UCRT (Windows 10 1803+) takes ".UTF-8" as a codepage suffix; the name
        // setlocale returns carries it ("English_United States.utf8"), or the
        // codepage number 65001.
        const utf8 = got != &null
            && (cxx::std::strstr(got, "utf8".c_str()) != &null
                || cxx::std::strstr(got, "UTF-8".c_str()) != &null
                || cxx::std::strstr(got, "65001".c_str()) != &null)
        if !utf8 {
            cxx::std::setlocale(kairo::lc_ctype, ".UTF-8".c_str())
        }
    } else {
        const cs = kairo::langinfo_codeset()
        const utf8 = cs != &null
            && (cxx::std::strstr(cs, "UTF-8".c_str()) != &null
                || cxx::std::strstr(cs, "UTF8".c_str()) != &null
                || cxx::std::strstr(cs, "utf8".c_str()) != &null)
        if !utf8 {
            // glibc >= 2.35 and musl spell the bare one "C.UTF-8", macOS "UTF-8";
            // en_US.UTF-8 for everything older. The first that exists wins.
            if cxx::std::setlocale(kairo::lc_ctype, "C.UTF-8".c_str()) == &null
                && cxx::std::setlocale(kairo::lc_ctype, "en_US.UTF-8".c_str()) == &null {
                cxx::std::setlocale(kairo::lc_ctype, "UTF-8".c_str())
            }
        }
    }

    const empty: [c_wchar; 1] = [0 as c_wchar]
    cxx::std::wcslen(unsafe &empty[0])
}
