// The four-word library answers to the two-word library's member names, with
// the two-word signatures: code that uses them compiles against either
// library. Each member is checked against the four-word member it stands for,
// with a heap-owning element type so moves out of a slot run destructors.

import std::io::*

fn main() -> i32 {
    var bad = 0

    var s: string = "hey"
    var e: string = ""
    if s.is_empty() || !e.is_empty() { bad += 1 }
    if s.data() != s.as_ptr() || s.data()[1] != 101 { bad += 2 }

    var v: [string] = ["a", "bb"]
    if v.is_empty() { bad += 4 }
    var p = v.pop()
    if !p? || (p ?? "") != "bb" || v.size() != 1 { bad += 8 }
    v.pop()
    var q = v.pop()
    if q? || !v.is_empty() { bad += 16 }

    var m: {string: string} = {}
    var r1 = m.try_insert("k", "one")
    var r2 = m.try_insert("k", "two")
    if r1? || (r2 ?? "") != "two" || m["k"] != "one" { bad += 32 }
    m.try_insert("j", "three")
    m.try_insert("l", "four")
    var g = m.swap_remove("k")
    if (g ?? "") != "one" || m.size() != 2 || m.swap_remove("zz")? { bad += 64 }
    var h = m.shift_remove("j")
    if (h ?? "") != "three" || m.size() != 1 || !m.contains("l") { bad += 128 }

    var st: {string} = {}
    st.insert("x")
    st.insert("y")
    if !st.swap_remove("x") || st.swap_remove("x") || !st.shift_remove("y") || !st.is_empty() { bad += 256 }
    if !m.swap_remove("l")? || !m.is_empty() { bad += 512 }

    var w: [u32] = [1, 2, 3]
    if (w.pop() ?? 0) != 3 || w.size() != 2 { bad += 1024 }
    var n: {u32: u32} = {}
    n.try_insert(1, 10)
    n.try_insert(2, 20)
    if (n.shift_remove(1) ?? 0) != 10 || (n.swap_remove(2) ?? 0) != 20 || !n.is_empty() { bad += 2048 }

    println(f"bad={bad}")
    return bad
}

// --- lit wiring ---
// CHECK: bad=0
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
