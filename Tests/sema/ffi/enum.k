// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// An unscoped enum's enumerators are visible BOTH unqualified and through
// the enum (`Color::Green`, legal C++11). clang calls an unscoped enum a
// transparent context; DeclImport must not see through it, or the
// enumerators land only in the enclosing scope and the qualified form
// misses. A scoped enum's are reachable only through it.

ffi "c++" import "enum.h"

fn use_enum() {
    var c = Red
    var d = Color::Green
    var m = Mode::Fast
    var f = favorite()
}

// DIAG-NOT: error

// SEMA:      use     Red  {{.*}} -> variant Red @ 5:14  [import overlay]
// SEMA:      use     Color  {{.*}} -> enum Color @ 5:1  [import overlay]
// SEMA-NEXT: member  ::Green  {{.*}} -> variant Green @ 5:19  [member of Color]
// SEMA:      use     Mode  {{.*}} -> enum Mode @ 7:1  [import overlay]
// SEMA-NEXT: member  ::Fast  {{.*}} -> variant Fast @ 7:35  [member of Mode]
// SEMA:      use     favorite  {{.*}} -> fn favorite @ 9:1  [import overlay]
// SEMA:      2 chain step(s): 2 bound, 0 overload sets, 0 open
