// `else eval if c { }` continues a chain as the nested form
// `else { eval if c { } }` does: the rest of the chain after it is `eval`
// too, and every condition of it folds. After a run-time `if`, the eval
// part folds inside that branch.

eval MODE: i32 = 2

fn pick() -> i32 {
    eval if MODE == 1 {
        return 10
    } else eval if MODE == 2 {
        return 20
    } else {
        return 30
    }
}

fn pick_rt(n: i32) -> i32 {
    if n > 5 {
        return 1
    } else eval if MODE == 2 {
        return 2
    } else {
        return 3
    }
}

fn main() -> i32 {
    return pick() + pick_rt(0) - 22
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s
// CHECK-NOT:   error [
// CHECK-LABEL: pick() noexcept {
// CHECK-NOT:   MODE
// CHECK:       return 20;
// CHECK-NOT:   return 10;
// CHECK-NOT:   return 30;
// CHECK:       }

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
