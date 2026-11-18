// math_c.k through `ffi "c++"`: the same wrapper, the same #include_next.

ffi "c++" import "math.h"

fn main() -> i32 {
    return sqrt(1764.0) as i32
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
