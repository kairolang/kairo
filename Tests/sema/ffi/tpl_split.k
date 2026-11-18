// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// A class template FORWARD-DECLARED in one header (tpl_fwd.h) and defined in
// another (tpl_def.h) -- the shape of every libc++ container. The Kairo decl
// is minted from the first sighting, so it belongs to tpl_fwd.h's TU, while
// its members arrive from tpl_def.h's walk. Their keys must be interned in
// the imm space of the TU that OWNS the table (tpl_fwd.h), or the members
// exist and no lookup can find them.

ffi "c++" import "tpl_def.h"

fn use_vec() -> u64 {
    var v: Vec<i32>
    var x: i32 = 1
    v.push(x)
    return v.size()
}

// DIAG-NOT: error

// SEMA:      member  .push  {{.*}} -> fn push @ 7:5  [member of Vec]
// SEMA:      member  .size  {{.*}} -> fn size @ 8:5  [member of Vec]
// SEMA:      0 unknown, 0 errored
