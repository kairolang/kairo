// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// A dependent DEFAULT template argument keeps its qualifiers when spelled
// back. `std::map<i32, i32>` defaults its allocator to
// `allocator<pair<const Key, T>>`, and libc++ static_asserts (map:934,
// "Allocator::value_type must be same type as value_type") that it matches
// exactly. Before qualifiers entered the canonical, TypeImport mapped
// `const int` to i32, the default came back as `allocator<pair<int, int>>`,
// the assert rejected the specialization and the fill failed. Now the const
// rides through import (qualified(CONST, i32)) and export (withConst), and
// the instance is filled by clang.
//
// `m.value_comp()(p, p)` -- the original body -- needs a call through a
// class-type object's `operator()`, which Kairo does not type yet; that is a
// separate gap, so the member used here is `size()`.

ffi "c++" import "map"

fn cmp() -> u64 {
    var m: cxx::std::map<i32, i32>
    return m.size()
}

// DIAG-NOT: error

// SEMA:      member  .size {{.*}} [member of map]  [filled by clang, {{[0-9]+}} bytes, align {{[0-9]+}}]
// SEMA:      0 unknown, 0 errored
