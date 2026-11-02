// `@packed` and `@align(N)` lay a record out as clang's
// `__attribute{{(__)?}}((packed))` / `__attribute__((aligned(N)))` do, and Sema's
// own layout (the size and alignment a declaration-scope `eval if` folds)
// is the same one: each folded branch below is checked against the
// run-time `sizeof` / `alignof`, which are C++'s. `@align(N)` on a field or
// variable raises its alignment the same way.

@packed struct P { var a: u8; var b: u32 }
@align(16) struct Q { var a: u8 }
@packed @align(4) struct PA { var a: u8; var b: u32 }
struct F { var a: u8; @align(8) var b: u8 }
@align(64) class Al64 { var v: i64  fn Al64(self, v: i64) { self.v = v } }

eval if sizeof P == 5 { fn p_size() -> usize { return 5 } } else { fn p_size() -> usize { return 0 } }
eval if alignof P == 1 { fn p_align() -> usize { return 1 } } else { fn p_align() -> usize { return 0 } }
eval if (sizeof Q == 16) && (alignof Q == 16) { fn q_ok() -> bool { return true } } else { fn q_ok() -> bool { return false } }
eval if (sizeof PA == 8) && (alignof PA == 4) { fn pa_ok() -> bool { return true } } else { fn pa_ok() -> bool { return false } }
eval if (sizeof F == 16) && (alignof F == 8) { fn f_ok() -> bool { return true } } else { fn f_ok() -> bool { return false } }
eval if (sizeof Al64 == 64) && (alignof Al64 == 64) { fn al_ok() -> bool { return true } } else { fn al_ok() -> bool { return false } }

@align(32) var g: i32 = 7

fn main() -> i32 {
    if p_size() != 5 { return 1 }
    if sizeof P != 5 { return 2 }
    if p_align() != 1 { return 3 }
    if alignof P != 1 { return 4 }
    if !q_ok() { return 5 }
    if (sizeof Q != 16) || (alignof Q != 16) { return 6 }
    if !pa_ok() { return 7 }
    if (sizeof PA != 8) || (alignof PA != 4) { return 8 }
    if !f_ok() { return 9 }
    if (sizeof F != 16) || (alignof F != 8) { return 10 }
    if !al_ok() { return 11 }
    if (sizeof Al64 != 64) || (alignof Al64 != 64) { return 12 }
    @align(64) var loc: i64 = 0
    if loc != 0 { return 13 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: struct __attribute{{(__)?}}((packed)) P
// CXX-DAG: struct __attribute{{(__)?}}((aligned(16))) Q
// CXX-DAG: struct __attribute{{(__)?}}((packed, aligned(4))) PA
// CXX-DAG: __attribute{{(__)?}}((aligned(8))) {{.*}}b
// CXX-DAG: class __attribute{{(__)?}}((aligned(64))) Al64
// CXX-DAG: __attribute{{(__)?}}((aligned(32))) {{.*}}g
// CXX-DAG: __attribute{{(__)?}}((aligned(64))) {{.*}}loc

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
