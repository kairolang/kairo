// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Member access on a receiver whose canonical is a C++ REFERENCE, reached
// from Kairo code rather than through libc++ internals (ref_field_member.k).
// Kairo has no source spelling for `T&` yet, so the references come from
// header functions. A reference is transparent to both separators: `.` on
// `box&`, and `->` on `box*&` (ref peeled first, then the pointer).

ffi "c++" import "ref_receiver.h"

fn via_lref() -> u64 { return lref_box().size() }
fn via_cref() -> u64 { return cref_box().size() }
fn via_rref() -> u64 { return rref_box().size() }
fn via_ptr_ref() -> u64 { return ptr_ref_box()->size() }
fn field_through_ref() -> i32 { return lref_box().v }

fn missing() { lref_box().nope() }

// DIAG:     ref_receiver.k:18:{{[0-9]+}}: error [R025E]: no member named 'nope' in 'box<int>'
// DIAG-NOT: error

// SEMA-DAG: member .size @ 12:{{[0-9]+}} -> {{.*}}[member of box]
// SEMA-DAG: member .size @ 13:{{[0-9]+}} -> {{.*}}[member of box]
// SEMA-DAG: member .size @ 14:{{[0-9]+}} -> {{.*}}[member of box]
// SEMA-DAG: member ->size @ 15:{{[0-9]+}} -> {{.*}}[member of box]
// SEMA-DAG: member .v @ 16:{{[0-9]+}} -> field v @ {{.*}}[member of box]
