// What std::c_wchar, c_char16 and c_char8 refuse. Like c_char they
// are characters, not numbers: a literal takes one only where it fits on
// every target (c_wchar 0..=0xFFFF, as wchar_t is 16 bits on Windows;
// c_char16 0..=0xFFFF; c_char8 0..=255), they do no arithmetic, they convert
// to and from an integer only with `as`, and never into one another. They
// compare and order. A u16 argument does not take a C++ `char16_t`
// parameter.

import std::c_wchar
import std::c_char16
import std::c_char8

ffi "c++" import "c_wchar_errors.h"

fn main() -> i32 {
    var a: c_wchar = 0x10000
    var b: c_char16 = 0x10000
    var c: c_char8 = 256
    var d: c_wchar = 0xFFFF
    var f = d + d
    var g: u32 = d
    var h = d as u32
    var k: c_char16 = d
    var m = (d < 5) && (h > 1)
    var n = pick(d) + pick(3i32)
    var p = takes16(3u16)
    var q = takes16(b)
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:16:22: error [SC075E]: literal '0x10000' does not fit in 'c_wchar' on every target: only 0 through 0xFFFF do, as wchar_t is 16 bits on Windows
// DIAG: {{.*}}:17:23: error [SC075E]: literal '0x10000' does not fit in 'c_char16'
// DIAG: {{.*}}:18:22: error [SC075E]: literal '256' does not fit in 'c_char8'
// DIAG: {{.*}}:20:13: error [SC067E]: arithmetic requires numeric operands, not 'c_wchar' and 'c_wchar'
// DIAG: {{.*}}:21:18: error [SC028E]: cannot convert 'c_wchar' to 'u32'; the conversion may lose value and needs an explicit 'as'
// DIAG: {{.*}}:23:23: error [SC028E]: cannot convert 'c_wchar' to 'c_char16'
// DIAG: {{.*}}:26:13: error [SC063E]: no matching overload for call to 'takes16'
// DIAG-NEXT: {{.*}}/c_wchar_errors.h:6:1: note [I900N]: candidate not viable: cannot convert argument of type 'u16' to parameter '__arg0' of type 'c_char16'
// END-GENERATED-CHECKS(DIAG)
