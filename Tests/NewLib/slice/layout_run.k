// A slice is two words, aligned as a word, and trivially copyable, for
// every element type, including a const element and one larger than the
// slice itself. The exit status says which property broke.

struct Big {
    var a: [u64; 9]
}

fn main() -> i32 {
    var w = sizeof usize
    if sizeof [i32;] != 2 * w || alignof [i32;] != alignof usize {
        return 1
    }

    if sizeof [const u8;] != 2 * w || sizeof [Big;] != 2 * w || sizeof [string;] != 2 * w {
        return 2
    }

    eval if !__builtin_is_trivially_copyable<[i32;]>() || !__builtin_is_trivially_copyable<[const Big;]>() {
        return 3
    }

    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
