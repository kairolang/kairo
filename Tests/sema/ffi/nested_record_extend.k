// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// A nested record reached from inside `extend holder<alloc>`: the bare name
// `node` resolves through the extended type (TypeResolve::_lookup_in_selfs,
// the third ensure_filled caller), which is the first thing in this file to
// look into `holder<alloc>`. Its members must be there. See nested_record.k.

ffi "c++" import "traits_typedef.h"

extend holder<alloc> {
    fn fresh(self) -> u64 { var n: node; return n.v + n.get() }
}

// DIAG-NOT: error

// SEMA:      member .v @ 12:{{[0-9]+}} -> field v @ {{[0-9]+:[0-9]+}} [member of node]
// SEMA:      member .get @ 12:{{[0-9]+}} -> fn get @ {{[0-9]+:[0-9]+}} [member of node]
// SEMA:      0 unknown, 0 errored
// SEMA:      0 of them dependent, 0 errored
