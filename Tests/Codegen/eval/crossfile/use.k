import lib::*

eval C = cube(2)

fn main() -> i32 {
    return C + Tbl::SIZE + (Tbl::BIG as i32) + Tbl::scaled(2) + hoisted()
        // 8 + 4 + 125 + 8 + 5 == 150
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 150
