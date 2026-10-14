/// --- The Kairo Project ----------------------------- Native/KLocale.hh --- ///
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
///   WHY C++: setlocale/nl_langinfo are platform headers stage0 cannot
///   `::`-qualify, and langinfo.h does not exist on Windows (which gets the
///   same treatment through UCRT's ".UTF-8" codepage suffix).
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_NATIVE_KLOCALE_HH__
#define __KAIRO_NATIVE_KLOCALE_HH__

#include <clocale>
#include <cstring>
#include <cwchar>

#if !defined(_WIN32)
#include <langinfo.h>
#endif

namespace kairo {

/// setlocale(LC_ALL, "") from the environment, then force LC_CTYPE to a UTF-8
/// codeset if that did not give one. LC_CTYPE only: the encoding, not the
/// numeric or message formats the user chose. Also touches the wide-string
/// machinery once on the calling thread: on Linux it resolves lazily and
/// segfaults if first called from a worker with a shallow stack.
inline void init_process_locale() {
    const char* got = ::setlocale(LC_ALL, "");
#if defined(_WIN32)
    // UCRT (Windows 10 1803+) takes ".UTF-8" as a codepage suffix; the name
    // setlocale returns carries it ("English_United States.utf8"), or the
    // codepage number 65001.
    bool utf8 = got && (::strstr(got, "utf8") || ::strstr(got, "UTF-8")
                        || ::strstr(got, "65001"));
    if (!utf8) { (void)::setlocale(LC_CTYPE, ".UTF-8"); }
#else
    (void)got;
    const char* cs   = ::nl_langinfo(CODESET);
    bool        utf8 = cs && (::strstr(cs, "UTF-8") || ::strstr(cs, "UTF8")
                              || ::strstr(cs, "utf8"));
    if (!utf8) {
        // glibc >= 2.35 and musl spell the bare one "C.UTF-8", macOS "UTF-8";
        // en_US.UTF-8 for everything older. The first that exists wins.
        (void)(::setlocale(LC_CTYPE, "C.UTF-8")
            || ::setlocale(LC_CTYPE, "en_US.UTF-8")
            || ::setlocale(LC_CTYPE, "UTF-8"));
    }
#endif
    (void)::wcslen(L"");
}

}  // namespace kairo

#endif  // __KAIRO_NATIVE_KLOCALE_HH__
