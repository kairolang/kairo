// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 13
//
// `var c = v.at(0)` infers the VALUE `v.at(0)` refers to, as `typeof` and a
// file-scope `var` already did and as C++'s `auto` does. A local kept the
// C++ reference (`i32&`, `unsafe *Node&`), so an if-expression joining it
// with a plain value failed (SC039E "does not unify with the earlier
// 'unsafe *DirEntry&'") -- and the local is a copy: writing it leaves the
// element alone.

ffi "c++" import "vector"

class Node { pub var n: i32 = 0 }

fn pick(ns: cxx::std::vector<unsafe *Node>, i: usize, ok: bool) -> unsafe *Node {
    var c = ns[i]
    return if ok => c else => &null
}

fn main() -> i32 {
    var v: cxx::std::vector<i32>
    v.push_back(4)
    var c = v.at(0)
    c += 5
    var ns: cxx::std::vector<unsafe *Node>
    ns.push_back(&null)
    var none = pick(ns, 0, false)
    // the element is still 4; the copy is 9: 4 + 9 = 13
    if none == &null { return v.at(0) + c }
    return 1
}

// DIAG-NOT: error
