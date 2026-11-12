// A C-style `for` may leave its init clause empty: it
// loops over a variable declared before it, and unlike the `while` it
// replaces, `continue` still runs the step. The first loop skips 3 and
// sums the rest of 0..9 (42); the second steps an iterator-like counter
// past every `continue` (it would never end without the step).

fn main() -> i32 {
    var i = 0
    var s = 0
    for ; i < 10; i += 1 {
        if i == 3 { continue }
        s += i
    }
    var k = 0
    var skipped = 0
    for ; k < 6; ++k {
        if k % 2 == 0 {
            skipped += 1
            continue
        }
    }
    // 42 + 3 + i (10) + k (6) = 61
    return s + skipped + i + k
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: IndexedForStmt
// AST-NOT: DeclStmt
// AST: BinaryOperatorExpr
// RUN: { %kairo %s --print-ir -o /dev/null 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR: for(;
// IR: for(;
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 61
