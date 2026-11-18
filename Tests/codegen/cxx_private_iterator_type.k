// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 51
//
// A C++ class may hand out an iterator whose type is a private or protected
// member alias; C++ callers never name it (`auto`). The emitter must not
// spell it either, for an inferred local or a for-each, or clang reports an
// access error that Kairo's own AccessCheck rightly never raised (I003E).

ffi "c++" import "cxx_private_iterator_type.h"

fn main() -> i32 {
    var b: Bag
    var sum = 0
    for x in b { sum += x }
    var it = b.begin()
    var e = b.end()
    while it != e { sum += *it; ++it }
    var d: Base
    for y in d { sum += y }
    var h: Holder
    for z in h.items() { sum += z }
    var dv: Derived
    var dp = &dv
    for w in dp->items() { sum += w }
    var cb: CmpBag
    if cb.find(1) != cb.end() { sum += 1 }
    var found = cb.find(7) == cb.end()
    if found { sum += 1 }
    var st: Set
    if st.find(1) != st.end() { sum += 1 }
    return sum * 1 + 0
}
