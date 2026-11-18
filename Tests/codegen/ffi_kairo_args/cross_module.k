// Kairo enums, ADTs and nullables in imported templates across a module
// boundary: lib.k declares the types and takes and returns the vectors;
// this file fills them. Both TUs spell one C++ type per vector, and each
// Kairo instance a fill names (`Nullable<Item*>`, `Nullable<int>`) is
// emitted where it is first needed, so the link finds it once.

ffi "c++" import "vector"
import lib::*

fn main() -> i32 {
    var ls: cxx::std::vector<Level>
    ls.push_back(Level::High)
    ls.push_back(Level::Low)
    ls.push_back(Level::High)
    var n = heavy(ls)                                     // 2

    var ss: cxx::std::vector<Slot<i32>>
    ss.push_back(Slot<i32>::Full { v: 10 })
    ss.push_back(.Hole)
    n += filled(ss)                                       // 12

    var a = Item(30)
    var ps: cxx::std::vector<*Item?>
    ps.push_back(&a)
    ps.push_back(null)
    n += weigh(ps)                                        // 42

    var hs = holes(3)
    for h in hs { n += h ?? 1 }                           // 42 + 3 + 3 = 48
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 48
