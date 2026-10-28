// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 16
//
// C and C++ keep tags apart from ordinary names, so glibc declares both
// `struct timezone` (<sys/time.h>) and `extern long timezone` (<time.h>).
// The plain name is the variable, the struct stays reachable through every
// signature that names it, and the import is not an ambiguity (R016E):
//   - across headers: the tag in tag.h, the variable in var.h;
//   - in one header: `struct st` beside the function `st`;
//   - `typedef struct pair pair` is one entity, not two.
// C++ reaches the hidden struct only elaborated, so the emitted C++ spells
// it `struct ::timezone`, and the program links and runs.

ffi "c++" import "Inputs/tag_hiding/all.h"
ffi "c++" import "Inputs/tag_hiding/all.h" as h

fn use_all() -> i32 {
    var off: i64 = timezone
    var p = get_tz()
    var q: unsafe *pair = &null
    return tz_minutes(p) + st(1) + (off as i32) + (h::timezone as i32) + h::st(2)
}

fn main() -> i32 {
    return use_all()    // 5 + 2 + 3 + 3 + 3
}

// DIAG-NOT: error

// SEMA:      use     timezone {{.*}} -> var timezone @ 1:1  [import overlay]
// SEMA:      use     st {{.*}} -> fn st @ 3:1  [import overlay]
// SEMA:      member  ::timezone {{.*}} -> var timezone @ 1:1
// SEMA:      member  ::st {{.*}} -> fn st @ 3:1
// SEMA:      CallExpr {{.*}} : unsafe *timezone
// SEMA:      NullLiteralExpr {{.*}} : unsafe *pair

// IR: signed long off = ::timezone;
// IR: struct{{ ?}}::timezone * p = ::get_tz();
