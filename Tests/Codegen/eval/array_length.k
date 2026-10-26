// An `eval` constant is a compile-time constant usable as an array length
// (eval.mdx, Usage as generic arguments: "including array sizes"), at file
// scope, in a module and in a function, and so is arithmetic over eval
// constants: Sema folds the length (EVAL.md 0.1), so `[i32; N]` is the
// type `[i32; 3]`. Was an ICE ("CXXSpell: type with no canonical").

eval N = 3
eval BUFFER_SIZE = 4

module sizes { pub eval WIDE = 2 }

var buffer: [u8; BUFFER_SIZE]

fn first(p: *[i32; 3]) -> i32 { return (*p)[0] }   // [i32; N] is [i32; 3]

fn main() -> i32 {
    eval k = 2
    var a: [i32; N] = [1, 2, 3]
    var b: [i32; sizes::WIDE * 2] = [0, 0, 0, 5]
    buffer[3] = 4
    return first(&a) + a[1] + a[2] + (buffer[3] as i32) + b[3] + (sizeof [i64; k] as i32)
        // 1 + 2 + 3 + 4 + 5 + 16 == 31
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: unsigned char buffer[4]
// IR: signed int a[3]
// IR: signed int b[4]

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 31
