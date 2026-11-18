// Raw pointer arithmetic runs as C++'s own pointer arithmetic.
// `unsafe *u8 + n` moves n bytes, `unsafe *i32 + n` moves n * 4, `q - p`
// counts i32s, and the comparisons order addresses. None of it goes
// through the unsigned-carrier wrap form integer `+` / `-` use.

fn main() -> i32 {
    var arr: [i32; 12] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    var p: unsafe *i32 = &null
    var bytes: unsafe *u8 = &null
    unsafe {
        p = &arr[0] as unsafe *i32
        bytes = p as unsafe *u8
    }
    var unsafe *q = p + 10
    var unsafe *b3 = bytes + 3usize
    var unsafe *back = b3 - 3
    var unsafe *w = p
    w += 4
    w -= 1
    if (q - p) != 10 { return 1 }
    var span: usize = 0
    unsafe { span = (b3 as usize) - (bytes as usize) }
    if span != 3 { return 2 }
    if back != bytes { return 3 }
    if !(p < q) { return 4 }
    if !(q >= p) { return 5 }
    if (p > q) || (q <= p) { return 6 }
    unsafe {
        if *q != 10 { return 7 }
        if *w != 3 { return 8 }
    }
    return 42
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}pointer_arith_raw.k
// CXX: q ={{ ?}}(p + 10);
// CXX: b3 ={{ ?}}(bytes +
// CXX: (w += 4);
// CXX: (w -= 1);
// CXX: (q - p) != 10

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
