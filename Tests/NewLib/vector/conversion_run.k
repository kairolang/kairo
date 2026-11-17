// A vector passed to a `[T;]` or `[const T;]` parameter is converted, not
// moved, and a slice member is reached on a vector through the conversion.

fn bump(s: [i32;]) {
    s[0] += 1
}

fn first(const s: [const i32;]) -> i32 {
    return s[0]
}

fn main() -> i32 {
    var v: [i32] = [1, 2]
    bump(v)
    var d = v.data()
    return v[0] + first(v) - 4
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
