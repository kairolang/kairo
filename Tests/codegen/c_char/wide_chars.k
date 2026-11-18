// C++'s wchar_t, char16_t and char8_t import as std::c_wchar, c_char16 and
// c_char8, not as their width's integer: a Kairo value can be typed
// as one and passed to C++, `f(wchar_t)` and `f(int)` are two overloads,
// std::wstring / u16string round-trip with their exact specialization (
// was wstring re-spelled basic_string<int>), and allocator<wchar_t> and
// allocator<u32> are two instances in one TU (they shared one shell).

import std::io::println
import std::c_wchar
import std::c_char16
import std::c_char8

ffi "c++" import "wide_chars.h"

fn main() -> i32 {
    var w: c_wchar = 0x263A
    var h: c_char16 = 0x3B1
    var e: c_char8 = 0xE9
    var r = 0
    if code_w(w) == 0x263A { r += 1 }
    if code_16(h) == 0x3B1 { r += 2 }
    if code_8(e) == 0xE9 { r += 4 }

    var i: i32 = 7
    var u: u32 = 7
    println(f"{pick(w)} {pick(i)} {pick(u)} {pick16(h)} {pick16(7u16)} {pick8(e)} {pick8(7u8)}")

    var ws: cxx::std::wstring = make_wide()
    var us: cxx::std::u16string = make_u16()
    if wlen(ws) == 4 { r += 8 }
    if u16len(us) == 5 { r += 16 }
    if (ws[0] == 119) && (us[0] == 117) { r += 32 }    // 'w', 'u'
    unsafe {
        if wcount(ws.c_str()) == 4 { r += 64 }
    }

    var vw: cxx::std::vector<c_wchar>
    var vu: cxx::std::vector<u32>
    vw.push_back(wide_a())
    vu.push_back(5)
    vu.push_back(6)
    if (wvec_size(vw) == 1) && (vu.size() == 2) && ((vw[0] as u32) == 65) { r += 128 }

    println(f"{w} {h} {e}")
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: wchar_t w = 0x263A;
// CXX-NEXT: char16_t h = 0x3B1;
// CXX-NEXT: char8_t e = 0xE9;
// CXX: ::std::basic_string<wchar_t, ::std::char_traits<wchar_t>, ::std::allocator<wchar_t>> ws = ::make_wide();
// CXX: ::std::vector<wchar_t, ::std::allocator<wchar_t>> vw

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out; test $? -eq 255
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: 1 2 3 1 2 1 2
// OUT-NEXT: 9786 945 233
