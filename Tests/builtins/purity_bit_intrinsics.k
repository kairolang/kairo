// In this library the bit intrinsics are generic functions over the
// argument's width (`fn <T> __builtin_ctz(v: T) -> u32`); a `@pure`
// function calls them as it calls clang's, and copies into its own local.
@pure
fn tz(m: usize) -> usize {
    return (__builtin_ctz(m) >> 3) as usize + (__builtin_clz(m as u32) as usize)
}

@pure
fn load(p: unsafe *const u8) -> usize {
    var w: usize = 0
    unsafe { __builtin_copy(&w as unsafe *u8, p, sizeof usize) }
    return w
}

fn main() -> i32 {
    var b: [u8; 8] = [7, 0, 0, 0, 0, 0, 0, 0]
    return (tz(256) + load(unsafe &b[0])) as i32 - 31
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
