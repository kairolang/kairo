// A string literal's bytes as the C++ narrow literal EmitIR writes: a quote
// and a backslash escaped, every byte outside printable ASCII in three-digit
// octal. Octal never reads the digit after it into the escape (`\x07` then
// `9` is `\0079`, where C++'s `\x079` would be one character), and `??=` /
// `??/` stay as they are: C++17 has no trigraphs.
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
// CXX: ("quote\" back\\ tab\011 nl\012 cr\015 nul-ish\001 del\177"), 39, 39);
// CXX: ("\0079 then digits \033[0m ??= ??/ trigraph-like"), 41, 41);
// CXX: ("caf\303\251 \344\270\226\347\225\214 high\303\277\303\276"), 21, 14);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out; test $? -eq 101
