// `op []` on a `cxx::std::array<bool, 256>` picks the const or the
// non-const overload by the receiver: a mutable local indexes and assigns
// (`t['W' as u8] = true`), a `const` copy indexes read-only; neither is a
// const-versus-non-const tie (SC064E). Same for `end()` / `find` on a
// `cxx::std::map` receiver, mutable and const. Exit 0.

ffi "c++" import "array"
ffi "c++" import "map"

fn main() -> i32 {
    var t: cxx::std::array<bool, 256>
    t['W' as u8] = true
    const c: cxx::std::array<bool, 256> = t
    var r = 0
    if t['W' as u8] { r += 1 }
    if c['W' as u8] { r += 1 }
    var m: cxx::std::map<i32, i32>
    m[3] = 4
    var it = m.find(3)
    if it != m.end() { r += 1 }
    return r - 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: SC064E
// DIAG-NOT: error
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
