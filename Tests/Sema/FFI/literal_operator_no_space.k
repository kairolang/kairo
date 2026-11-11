// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// RUN: { %kairo %s -o %t.exe 2>&1 || true; } | %FileCheck %s --check-prefix=BUILD --allow-empty
// RUN: %t.exe; test $? -eq 5
// RUN: %kairo %s --print-ast=tree 2>&1 | %FileCheck %s --check-prefix=TREE
// A literal-operator call went out as `operator "" _len`, the spelling
// C++23 deprecated, and clang warned C271W at every use. The suffix belongs
// to the string token. The tree dump also shows the suffix.
// IR: n = ::operator ""_len("hello", 5)
// IR-NOT: C271W
// BUILD-NOT: C271W
// TREE: StringLiteralExpr "hello" suffix _len
ffi "c++" import "string_literal_suffix.h"

fn main() -> i32 {
    var n: usize = "hello"_len
    return n as i32
}
