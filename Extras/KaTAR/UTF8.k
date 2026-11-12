/// --- The Kairo Project ----------------------- Extras/KaTAR/UTF8.k ------ ///
///
///   wstring -> UTF-8 std::string conversion.
///   No <codecvt>, no locale streams.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "string"

import std::c_char

pub fn to_utf8(src: unsafe *(cxx::std::wstring)) -> cxx::std::string {
    var out: cxx::std::string
    out.reserve(src->size())

    for wc in *src {
        var cp: u32 = (wc as u32)
        if cp < 0x80 {
            out.push_back((cp as u8) as c_char)
        } else if cp < 0x800 {
            out.push_back(((0xC0 | cp >> 6) as u8) as c_char)
            out.push_back(((0x80 | cp & 0x3F) as u8) as c_char)
        } else if cp < 0x10000 {
            out.push_back(((0xE0 | cp >> 12) as u8) as c_char)
            out.push_back(((0x80 | cp >> 6 & 0x3F) as u8) as c_char)
            out.push_back(((0x80 | cp & 0x3F) as u8) as c_char)
        } else {
            out.push_back(((0xF0 | cp >> 18) as u8) as c_char)
            out.push_back(((0x80 | cp >> 12 & 0x3F) as u8) as c_char)
            out.push_back(((0x80 | cp >> 6 & 0x3F) as u8) as c_char)
            out.push_back(((0x80 | cp & 0x3F) as u8) as c_char)
        }
    }

    return out
}
