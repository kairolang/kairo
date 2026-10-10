fn pick(c: i32) -> i32 = if c == 0 => 10 else if c > 5 => 20 else => 30

fn f2(x: i32, y: i32) -> i32 = x + y

fn main() -> i32 {
    var a = pick(0) + pick(9) + pick(3)                 // 10 + 20 + 30 = 60
    var d = f2(if a > 0 => 1 else => 0, 2)              // 1 + 2 = 3
    var e = if a < 0 => 0 else => a + 1                 // the last arm is `a + 1`: 61
    return a + d + e - 114                              // 10
}

// --- lit wiring -----------------------------------------------------------
// End to end: `=>` value arms of `if` compile, link and run. pick() is an
// else-if chain, the call argument shows the last arm ending at `,`, and `e`
// shows the last arm running to the end of the initializer (61, not 1).
// 60 + 3 + 61 - 114 == 10. `match` and `try` value arms do not reach EmitIR
// yet; they are type-checked in values_pending.k.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 10
