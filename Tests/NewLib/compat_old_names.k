// The old library's member names on the two-word library: each forwarder in
// compat.k compiles, does what the old member did, and warns at the call
// with the member to use.

import std::io::*

fn main() -> i32 {
    var bad = 0

    var s = "hello world"
    if s.length() != 11 { bad += 1 }
    if s.as_ptr() != s.data() { bad += 1 }
    if s.empty() { bad += 1 }
    var mid = s.subslice(6, 100)
    if mid != "world" { bad += 1 }
    if s.subslice(50, 3).size() != 0 { bad += 1 }

    var v: [i32]
    v.push_back(1)
    v.push_back(2)
    v.push_back(3)
    if v.empty() { bad += 1 }
    *v.front() += 10
    *v.back() += 20
    if v[0] != 11 || v[2] != 23 { bad += 1 }
    v.pop_back()
    if v.size() != 2 { bad += 1 }

    var m: {u64: u64}
    if !m.empty() { bad += 1 }
    if !m.emplace(1, 10) { bad += 1 }
    if m.emplace(1, 99) || m[1] != 10 { bad += 1 }
    m.emplace(2, 20)
    if !m.erase(1) || m.erase(1) { bad += 1 }
    if !m.erase_ordered(2) || m.size() != 0 { bad += 1 }

    var h: {u64}
    if !h.empty() { bad += 1 }
    h.insert(4)
    h.insert(5)
    if !h.erase(4) || h.erase(4) { bad += 1 }
    if !h.erase_ordered(5) || h.size() != 0 { bad += 1 }

    if bad == 0 {
        println("ok")
    }

    return bad
}

// WARN-DAG: :11:{{[0-9]+}}: warning [SC146W]: {{.*}}length{{.*}}use size()
// WARN-DAG: :12:{{[0-9]+}}: warning [SC146W]: {{.*}}as_ptr{{.*}}use data()
// WARN-DAG: :13:{{[0-9]+}}: warning [SC146W]: {{.*}}empty{{.*}}use is_empty()
// WARN-DAG: :14:{{[0-9]+}}: warning [SC146W]: {{.*}}subslice{{.*}}use s[pos..pos + n]
// WARN-DAG: :19:{{[0-9]+}}: warning [SC146W]: {{.*}}push_back{{.*}}use push()
// WARN-DAG: :22:{{[0-9]+}}: warning [SC146W]: {{.*}}empty{{.*}}use is_empty()
// WARN-DAG: :23:{{[0-9]+}}: warning [SC146W]: {{.*}}front{{.*}}use v[0]
// WARN-DAG: :24:{{[0-9]+}}: warning [SC146W]: {{.*}}back{{.*}}use v[v.size() - 1]
// WARN-DAG: :26:{{[0-9]+}}: warning [SC146W]: {{.*}}pop_back{{.*}}use pop()
// WARN-DAG: :30:{{[0-9]+}}: warning [SC146W]: {{.*}}empty{{.*}}use is_empty()
// WARN-DAG: :31:{{[0-9]+}}: warning [SC146W]: {{.*}}emplace{{.*}}use try_insert()
// WARN-DAG: :34:{{[0-9]+}}: warning [SC146W]: {{.*}}erase{{.*}}use swap_remove()
// WARN-DAG: :35:{{[0-9]+}}: warning [SC146W]: {{.*}}erase_ordered{{.*}}use shift_remove()
// WARN-DAG: :38:{{[0-9]+}}: warning [SC146W]: {{.*}}empty{{.*}}use is_empty()
// WARN-DAG: :41:{{[0-9]+}}: warning [SC146W]: {{.*}}erase{{.*}}use swap_remove()
// WARN-DAG: :42:{{[0-9]+}}: warning [SC146W]: {{.*}}erase_ordered{{.*}}use shift_remove()

// CHECK: ok

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=WARN
// RUN: %t.exe | %FileCheck %s
