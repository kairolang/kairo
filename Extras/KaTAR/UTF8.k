/// --- The Kairo Project ----------------------- Extras/KaTAR/UTF8.k ------ ///
///
///   wstring -> UTF-8 std::string conversion.
///   No <codecvt>, no locale streams.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

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