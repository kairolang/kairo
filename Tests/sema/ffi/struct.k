// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// A C aggregate through an ALIASED ffi import. The alias is the header's own
// module (sema/Foreign names it after the file), `s::Point` is a type
// position through it, a field is reached through a value of that type, and
// a free function takes the record by value. Every name binds to a decl
// imported from clang's AST -- the positions on the right of each binding are
// lines of struct.h, not of this file.

ffi "c++" import "struct.h" as s

fn use_struct() -> i32 {
    var p: s::Point
    var a = p.x
    return s::point_sum(p) + a
}

// DIAG-NOT: error

// SEMA:      member  .x  {{.*}} -> field x @ 5:5  [member of Point]
// SEMA:      use     s  {{.*}} -> module struct @ 1:1  [import overlay]
// SEMA-NEXT: member  ::point_sum  {{.*}} -> fn point_sum @ 9:1
// SEMA:      0 unknown, 0 errored
