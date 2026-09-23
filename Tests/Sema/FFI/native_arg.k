// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// `cont<Point>` with a KAIRO struct as the argument. clang's AST has never
// heard of `Point`, so TypeExport declares a stand-in for it there first
// (a struct with Point's fields, under the name EmitIR gives Point), and
// the instance fills from clang exactly as `cont<i32>` does in
// traits_typedef.k. Before the stand-in the fill failed and lookup fell
// back to the pattern, where `size()`'s dependent `size_type` came back
// opaque.

ffi "c++" import "traits_typedef.h"

struct Point {
    var x: i32
    var y: i32
}

fn use_native() {
    var c: cont<Point>
    var p: Point
    c.push(p)
    var n = c.size()
}

// DIAG-NOT: error

// Both rows come from the INSTANCE's table (the marker), with clang's
// layout of `cont<Point>` -- `T* first` + `unsigned long n` -- and size()'s
// `size_type` is clang's `unsigned long`.
// SEMA:      member  .push  {{.*}} -> fn push @ 14:5  [member of cont]  [filled by clang, 16 bytes, align 8]
// SEMA:      member  .size  {{.*}} -> fn size @ 13:5  [member of cont]  [filled by clang, 16 bytes, align 8]
// SEMA:      0 unknown, 0 errored
// SEMA:      -- inferred decls --
// SEMA-NEXT: n : u64
