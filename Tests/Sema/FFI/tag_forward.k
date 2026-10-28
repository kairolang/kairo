// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 10
//
// A bodiless `ffi "c" struct T` (or `class`, `union`) in a file with ffi
// imports is a forward declaration of the HEADER's tag, not a new Kairo
// type. It is how source names a tag an ordinary name hides
// (tag_hiding.k): in a TYPE position `timezone` is now the struct, while a
// VALUE `timezone` is still the variable, as C keeps the two apart. A tag
// nothing hides can be named the same way. With no such tag in the
// closure, the declaration stays a Kairo forward declaration.

ffi "c++" import "Inputs/tag_hiding/all.h"

ffi "c" struct timezone
ffi "c" struct pair
ffi "c" struct only_kairo

fn use_forward() -> i32 {
    var p: unsafe *timezone = get_tz()
    var off: i64 = timezone
    var q: *pair = &null
    var k: *only_kairo = &null
    return tz_minutes(p) + (off as i32) + st(1)    // 5 + 3 + 2
}

fn main() -> i32 {
    return use_forward()
}

// DIAG-NOT: error

// SEMA:      use     get_tz {{.*}} -> fn get_tz @ 4:1  [import overlay]
// SEMA:      use     timezone {{.*}} -> var timezone @ 1:1  [import overlay]
// SEMA:      CallExpr {{.*}} : unsafe *timezone

// IR-NOT:    struct timezone {
// IR-NOT:    struct pair {
// IR:        struct{{ ?}}::timezone * p = ::get_tz();
// IR:        signed long off = ::timezone;
