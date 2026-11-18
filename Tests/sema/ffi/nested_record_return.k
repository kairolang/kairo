// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// A nested record reached ONLY as a member's return type: no type path in
// this file names `node`. The `.first` lookup fills `holder<alloc>` (the
// MemberLookup caller of ensure_filled), that fill completes `node`, and
// `.v` / `.get` then read its members. See nested_record.k.

ffi "c++" import "traits_typedef.h"

fn via_return() -> u64 {
    var h: holder<alloc>
    return h.first().v + h.first().get()
}

// DIAG-NOT: error

// SEMA:      member .first @ 13:{{[0-9]+}} -> fn first @ {{[0-9]+:[0-9]+}} [member of holder] [filled by clang
// SEMA:      member .v @ 13:{{[0-9]+}} -> field v @ {{[0-9]+:[0-9]+}} [member of node]
// SEMA:      member .get @ 13:{{[0-9]+}} -> fn get @ {{[0-9]+:[0-9]+}} [member of node]
// SEMA:      0 unknown, 0 errored
// SEMA:      0 of them dependent, 0 errored
