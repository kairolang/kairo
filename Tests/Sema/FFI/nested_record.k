// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Nested records of an instance of an IMPORTED template, reached by a
// written type path. clang's implicit instantiation of `holder<alloc>`
// DECLARES `holder<alloc>::node` but does not define it (a member class is
// defined only when required complete), so the fill used to bind `node` as
// a type with no members. The fill now completes the nested records its own
// walk reaches (ForeignInstantiate::_complete_nested) -- two levels deep
// here, `node::tag`. nested_record_return.k and nested_record_extend.k reach
// `node` through the other ensure_filled callers.

ffi "c++" import "traits_typedef.h"

fn spelled() -> u64 {
    var b: holder<alloc>::node
    var p: unsafe *holder<alloc>::node = b.next   // a C++ `node*` is raw
    return b.v + b.get()
}

fn two_levels() -> i32 {
    var t: holder<alloc>::node::tag
    return t.id + t.kind()
}

// DIAG-NOT: error

// SEMA:      member .next @ 17:{{[0-9]+}} -> field next @ {{[0-9]+:[0-9]+}} [member of node]
// SEMA:      member .v @ 18:{{[0-9]+}} -> field v @ {{[0-9]+:[0-9]+}} [member of node]
// SEMA:      member .get @ 18:{{[0-9]+}} -> fn get @ {{[0-9]+:[0-9]+}} [member of node]
// SEMA:      member .id @ 23:{{[0-9]+}} -> field id @ {{[0-9]+:[0-9]+}} [member of tag]
// SEMA:      member .kind @ 23:{{[0-9]+}} -> fn kind @ {{[0-9]+:[0-9]+}} [member of tag]
// SEMA:      0 unknown, 0 errored
// SEMA:      0 of them dependent, 0 errored
