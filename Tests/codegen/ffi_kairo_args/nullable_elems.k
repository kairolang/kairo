// `cxx::std::vector<i32?>`: a Kairo nullable as an imported template's
// argument. To C++ `i32?` is `::builtin::Nullable<int>`, which phase A only
// knows through the Nullable lang item's stand-in; every member type the
// fill reads back through it is `i32?` again, so `push_back` takes
// `const i32?&` (a value and `null` both convert to it), `[]`/`at`/`back`
// hand out `i32?&`, and the elements narrow with `?` like any nullable.
//
// `Nullable<i32>` itself is named by no Kairo expression here -- only the
// fill spells it -- so its explicit instantiation must be homed in this TU,
// or the link misses its constructors.

ffi "c++" import "vector"

fn count_present(v: cxx::std::vector<i32?>) -> i32 {
    var n = 0
    for x in v { if x? { n += 1 } }
    return n
}

fn main() -> i32 {
    var v: cxx::std::vector<i32?>
    v.push_back(3)
    v.push_back(null)
    var four: i32? = 4
    v.push_back(four)
    var gone: i32? = null
    v.push_back(gone)

    var n = 0
    for x in v { if x? { n += x } else { n += 10 } }      // 3 + 10 + 4 + 10 = 27
    var first? = v[0]
    if first? { n += first }                              // 30
    var last? = v.back()
    if last? { n += 100 }                                 // last is null: 30
    var second? = v.at(1)
    n += second ?? 5                                      // 35
    n += count_present(v) * 1000                          // 2035
    return n - 2000                                       // 35
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 35
