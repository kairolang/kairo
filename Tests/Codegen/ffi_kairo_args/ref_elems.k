// Reading and writing an imported container's elements in place, through
// the C++ reference `operator[]` / `at` / `back` return: a nullable element
// is tested (`v[0]?`, `== null`), coalesced (`v[1] ?? 4`) and assigned
// (`v[0] = 5`, `v[0] = null`, `m[k] = 5`) as the `i32?` it refers to. A
// converted right side is written as the element type, not cast to the
// reference -- the same for a plain widening (`w[0] = x`, i32 into i64).

ffi "c++" import "vector"
ffi "c++" import "map"

fn main() -> i32 {
    var v: cxx::std::vector<i32?>
    v.push_back(1)
    v.push_back(null)
    var n = 0
    if v[0]? { n += 1 }                                   // 1
    if v[1] == null { n += 2 }                            // 3
    n += v[1] ?? 4                                        // 7
    n += v.at(0) ?? 100                                   // 8
    v[0] = 5
    v[1] = 6
    n += (v[0] ?? 0) + (v.back() ?? 0)                    // 19
    v[0] = null
    n += v[0] ?? 20                                       // 39

    var m: cxx::std::map<i32, i32?>
    m[1] = 5
    m[2] = null
    n += (m[1] ?? 0) + (m[2] ?? 10)                       // 54

    var w: cxx::std::vector<i64>
    w.push_back(1)
    var x: i32 = 7
    w[0] = x
    var r: i64 = w[0]
    return n + (r as i32)                                 // 61
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 61
