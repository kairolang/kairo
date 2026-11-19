// A vector built from a foreign contiguous range (a std::vector here, met
// structurally through data() and size()) copies its elements and owns
// them; an empty range gives the empty vector.

ffi "c++" import "vector"

import std::io

fn main() -> i32 {
    var bad = 0
    var cv = cxx::std::vector<i32>()
    for var i: i32 = 0; i < 100; ++i {
        cv.push_back(i * 3)
    }

    var v = Vector<i32>(cv)
    if v.size() != 100 || v.capacity() != 100 || v[99] != 297 {
        bad += 1
    }

    cv.clear()
    if v[1] != 3 {
        bad += 1
    }

    var e = Vector<i32>(cv)
    if e.size() != 0 || e.capacity() != 0 {
        bad += 1
    }

    io::println(f"elemrange: bad={bad}")
    return bad
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK: elemrange: bad=0
