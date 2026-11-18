// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 8
//
// A C++ unscoped enumerator named through its enclosing record
// (`LS::b`, of `LS::Kind`; clang's `LangStandard::lang_gnucxx26`) is the
// enum's value. MemberTyping kept the qualifier's type for a variant step
// (meant for `Foo<i32>::V` on a generic enum), so it typed as `LS` and
// `setk(k)` would be SC063E "cannot convert argument of type 'LS' to parameter
// 'k' of type 'Kind'" (as in Support/TermRenderer.k).
//

// DIAG-NOT: error

ffi "c++" import "unscoped_enum_in_record.h"

fn main() -> i32 {
    var k = LS::b
    var r = setk(k)
    k = LS::a
    return r + setk(k)
}
