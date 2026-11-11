// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 13
// The abstract element iterated by pointer (`for *x`) builds and runs;
// by value is the Kairo error in cxx_for_abstract_elem.k.
ffi "c++" import "cxx_for_abstract_elem.h"

fn main() -> i32 {
    var r = Shapes()
    var n: i32 = 0
    for *x in r {
        n += x->area()
    }
    return n
}
