// `a.size()` on a fixed array `[T; N]` is N, a compile-time constant
// whatever the elements hold: it is an array length (`[u8; a.size()]`,
// arithmetic over it, a nested array's row), an `eval` binding's value at
// module and at function scope, and an `eval if` condition, and
// `a.is_empty()` is one too.

import std::io

var table: [u16; 5]

eval TABLE_LEN: usize = table.size()

fn main() -> i32 {
    var a: [i32; 4] = [1, 2, 3, 4]
    var b: [u8; a.size()]
    var grid: [[i32; 3]; 2] = [[1, 2, 3], [4, 5, 6]]
    var row: [i64; grid[0].size() + TABLE_LEN]
    eval n = a.size()
    eval empty = a.is_empty()
    eval if a.size() == 4 {
        io::println("eval if: four")
    } else {
        io::println("eval if: not four")
    }

    io::println(f"n {n} empty {empty} b {b.size()} rows {grid.size()} row {row.size()} table {TABLE_LEN}")
    return (n + b.size() + row.size()) as i32
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe > %t.out; test $? -eq 16
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK:      eval if: four
// CHECK-NEXT: n 4 empty false b 4 rows 2 row 8 table 5
