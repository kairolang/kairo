// SI2: `unsafe *(unsafe *c_char)` -> `unsafe *(unsafe *const c_char)` adds
// const two pointers deep, which reinterpret_cast refuses as casting away
// qualifiers; the emitter uses the C-style cast.
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 65

import std::c_char

fn main() -> i32 {
    var s: c_char = 65
    var p: unsafe *c_char = unsafe &s
    var pp: unsafe *(unsafe *c_char) = unsafe &p
    var q: unsafe *(unsafe *const c_char) = unsafe (pp as unsafe *(unsafe *const c_char))
    return unsafe (**q) as i32
}
