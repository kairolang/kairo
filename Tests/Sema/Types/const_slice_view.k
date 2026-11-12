// `[T;]` and `[T]` convert implicitly to `[const T;]`, as `*T` does to
// `*const T`: a read-only view of the same elements, nothing copied. The
// reverse, and a different element type, stay errors.
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
// RUN: { %kairo %s --type-check-only -DBAD 2>&1 || true; } | %FileCheck %s

fn sum(const s: [const u8;]) -> i32 {
    var t = 0
    for x in s {
        t += x
    }

    return t
}

fn first(const s: [const u8;]) -> u8 {
    return s[0]
}

fn main() -> i32 {
    var v: [u8]           = [1, 2, 3]
    var s: [u8;]          = v
    var c: [const u8;]    = s
    var d: [const u8;]    = v
    const cv: [u8]        = [4]
    if sum(v) + sum(s) + sum(c) + sum(d) + sum(cv) != 28 {
        return 1
    }

    v[0] = 9
    if first(v) != 9 || d[0] != 9 {
        return 2
    }

    eval if defined!(BAD) {
        // CHECK: const_slice_view.k:[[@LINE+1]]:27: error [SC028E]: cannot convert '[const u8;]' to '[u8;]'
        var back: [u8;] = c
        // CHECK: const_slice_view.k:[[@LINE+1]]:34: error [SC028E]: cannot convert '[u8]' to '[const i8;]'
        var other: [const i8;] = v
    }

    return 0
}
