// A pack is a Slice<E> by value, in any position; the parameters after it are
// keyword-only; an empty pack is a zero-length slice.

fn chk(c: bool) -> i32 { if c { return 1 } return 0 }

fn count(const ...s: string, end: i32 = 7) -> i32 { return (s.len as i32) * 10 + end }

fn sum(...xs: i32) -> i32 {
    var t = 0
    for var i: usize = 0; i < xs.len; ++i { t += xs.data[i] }
    return t
}

fn mid(a: i32, ...xs: i32, b: i32 = 100) -> i32 { return a + (xs.len as i32) + b }

fn main() -> i32 {
    var n = chk(count("a", "b") == 27)
    n += chk(count() == 7)
    n += chk(count("a", end: 1) == 11)
    n += chk(sum(1, 2, 3) == 6)
    n += chk(sum() == 0)
    n += chk(mid(1, 2, 3, b: 5) == 8)
    n += chk(mid(1) == 101)
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-lowered 2>&1 || true; } | %FileCheck %s --check-prefix=LOW
// LOW: SEMA fid {{[0-9]+}}: {{.*}}packs.k
// LOW: __kairo_default_count_end
// LOW: [i32;]
// RUN: { %kairo %s --print-lowered 2>&1 || true; } | %FileCheck %s --check-prefix=NONAMED
// NONAMED: SEMA fid {{[0-9]+}}: {{.*}}packs.k
// NONAMED-NOT: NamedArgExpr
// NONAMED-NOT: ListLiteralExpr

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 7
