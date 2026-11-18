// `vector<*Node>` across a module boundary: lib.k declares Node and takes
// and returns through the vector; this file fills it. Both modules must
// agree the element is `*Node`, and their C++ must name one type.

ffi "c++" import "vector"
import lib::*

fn main() -> i32 {
    var a = Node(3)
    var b = Node(9)
    var v: cxx::std::vector<*Node>
    v.push_back(&a)
    v.push_back(&b)
    var *big = largest(v)
    return total(v) + big->id                 // 12 + 9
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 21
