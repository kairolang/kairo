// A member of a class template that is forward-declared in one header and
// defined in another is spelled correctly across the files' header contexts:
// user_a.k sees only fwd.h, user_b.k sees def.h (which includes fwd.h), and
// the constructor and member calls on `fx::Wrap<i32>` in user_b.k name the
// class through the table of the file the name lies in. The program builds and
// runs at -O0 and -O2.

import user_a::*
import user_b::*

fn main() -> i32 {
    if size_of_ptr() != 8 { return 1 }
    return make_and_read(41) - 42
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d/o2
// RUN: %t.exe
