// A string literal's bytes as EmitIR writes them: a constant array of the
// decimal byte values with a 0 after them, no C++ escape at all, so a quote,
// a backslash, a control byte, an escape followed by a digit (`\x07` then
// `9`) and `??=` / `??/` all reach the program unchanged. The string is
// built from the array, its byte count and its character count.
import std::io

fn main() -> i32 {
    var a = "quote\" back\\ tab\t nl\n cr\r nul-ish\x01 del\x7f"
    var b = "\x079 then digits \x1b[0m ??= ??/ trigraph-like"
    var c = "café 世界 high\xff\xfe"
    io::println(a)
    io::println(b)
    io::println(c)
    return (a.size() + b.size() + c.size()) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: 113, 117, 111, 116, 101, 34, 32, 98, 97, 99, 107, 92, 32, 116, 97, 98, 9, 32, 110, 108, 10, 32, 99, 114, 13, 32, 110, 117, 108, 45, 105, 115, 104, 1, 32, 100, 101, 108, 127, 0
// CXX-DAG: 7, 57, 32, 116, 104, 101, 110, 32, 100, 105, 103, 105, 116, 115, 32, 27, 91, 48, 109, 32, 63, 63, 61, 32, 63, 63, 47, 32, 116, 114, 105, 103, 114, 97, 112, 104, 45, 108, 105, 107, 101, 0
// CXX-DAG: 99, 97, 102, 195, 169, 32, 228, 184, 150, 231, 149, 140, 32, 104, 105, 103, 104, 195, 191, 195, 190, 0

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out; test $? -eq 101
