// A ref-qualified method on the wrong object is not viable, as in C++: an
// `&&` method on an lvalue, an `&` method on a temporary. Before, the
// qualifier was ignored and both calls compiled to C++ that clang refused.
// The right object still binds (the last two calls).

ffi "c++" import "refs.h"

fn main() -> i32 {
    var o = Only()
    var a = o.t()
    var b = make_only().u()
    var c = make_only().t()
    var d = o.u()
    return a + b + c + d
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:10:13: error [SC063E]: no matching overload for call to 't'
// DIAG-NEXT: {{.*}}/refs.h:49:5: note [I900N]: candidate not viable: 't' is '&&'-qualified; it can only be called on a temporary
// DIAG: {{.*}}:11:13: error [SC063E]: no matching overload for call to 'u'
// DIAG-NEXT: {{.*}}/refs.h:50:5: note [I900N]: candidate not viable: 'u' is '&'-qualified; it cannot be called on a temporary
// END-GENERATED-CHECKS(DIAG)
