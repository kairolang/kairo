// An argument that reaches a reference parameter through a conversion binds
// the converted TEMPORARY, an rvalue, so `T&&` beats `const T&` for it as
// for any rvalue ([over.ics.rank]/3.2.3). `vector<i64>::push_back(x)` with
// x: i32 has both overloads at rank Converted, and used to be SC064E "call
// to 'push_back' is ambiguous". An exact lvalue still takes `const T&`
// (T&& does not bind it), and an exact rvalue `T&&`, as before.

ffi "c++" import "vector"

fn main() -> i32 {
    var v: cxx::std::vector<i64>
    var x: i32 = 3
    v.push_back(x)                // converted: the temporary, T&&
    var y: i64 = 4
    v.push_back(y)                // exact lvalue: const T&
    v.push_back(5)                // literal: takes i64, T&&
    var s: i64 = v[0] + v[1] + v[2]
    return s as i32               // 12
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 12
