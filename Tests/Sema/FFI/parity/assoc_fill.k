// rule: an associative container's default allocator names
// `pair<const K, T>` (or `const K`), each fill spells that default back to
// clang, and libc++ static_asserts it matches value_type exactly -- so a
// lost `const` fails the fill. Both instances must come back filled by
// clang, and every call typed from the filled table.
//
// `m[1] = 2` rather than `m.insert({1, 2})`: Kairo cannot yet build the
// two-argument `std::pair` insert wants. The fill is what is under test.

ffi "c++" import "set"
ffi "c++" import "unordered_map"

fn use_assoc() {
    var s: cxx::std::set<i32>
    var m: cxx::std::unordered_map<i32, i32>
    s.insert(1)
    m[1] = 2
    var n = s.size() + m.size()
}

// DIAG-NOT: error

// SEMA:      member  .insert {{.*}} [member of set]  [filled by clang, {{[0-9]+}} bytes, align {{[0-9]+}}]
// SEMA:      member  .size {{.*}} [member of set]  [filled by clang, {{[0-9]+}} bytes, align {{[0-9]+}}]
// SEMA:      member  .size {{.*}} [member of unordered_map]  [filled by clang, {{[0-9]+}} bytes, align {{[0-9]+}}]
// SEMA:      0 unknown, 0 errored
// SEMA:      -- inferred decls --
// SEMA-NEXT: n : u64

// --- lit wiring -----------------------------------------------------------
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict. See Tests/parity_check.py.
//
// RUN: %parity %s
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// REQUIRES: clang
