// RUN: %kairo %s --type-check-only
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
// A string literal's suffix named an imported C++ `operator""_x` and was
// dropped: `"hello"_len` was a plain string. It is that operator's call,
// typed as its result; an unknown suffix is an error.
// IR: n = ::operator{{ ?}}""{{ ?}}_len("hello", 5)
ffi "c++" import "string_literal_suffix.h"

fn main() -> i32 {
    var n: usize = "hello"_len
    return n as i32
}
