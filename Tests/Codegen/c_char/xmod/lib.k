// A Kairo module whose public API speaks C strings: its signatures carry
// `*const c_char` across a module boundary, as `const char*` in both TUs.

import std::c_char

/// How many bytes before the NUL.
pub fn c_len(s: unsafe *const c_char) -> usize {
    var n: usize = 0
    unsafe { while s[n] != 0 { n += 1 } }
    return n
}

pub fn <T> first_of(s: unsafe *const T) -> T {
    unsafe { return s[0] }
}

pub fn shout() -> c_char { return 33 }
