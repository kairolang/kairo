// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// One C++ namespace spread over TWO headers of one include closure, and
// reopened twice inside the second. A BARE ffi import folds every header of
// the closure, so `geo` arrives as two ModuleDecls -- one per header, never
// one per USR -- linked into one redeclaration ring, so `geo` names ONE
// module and a `::` step searches every reopening, the reopened-module rule
// (IMPORTS.md §4.3). `area` lives only in ns_part.h, the other two only in
// ns_reopen.h; all three have to bind.

ffi "c++" import "ns_reopen.h"

fn use_ns() -> i32 {
    return geo::area(1, 2) + geo::perimeter(1, 2) + geo::volume(1, 2, 3)
}

// DIAG-NOT: error

// SEMA:      use     geo  {{.*}} -> module geo @ 5:1  [import overlay]
// SEMA-NEXT: member  ::area  {{.*}} -> fn area @ 6:1  [member of geo]
// SEMA:      use     geo  {{.*}} -> module geo @ 5:1  [import overlay]
// SEMA-NEXT: member  ::perimeter  {{.*}} -> fn perimeter @ 7:1  [member of geo]
// SEMA:      use     geo  {{.*}} -> module geo @ 5:1  [import overlay]
// SEMA-NEXT: member  ::volume  {{.*}} -> fn volume @ 11:1  [member of geo]
// SEMA:      3 chain step(s): 3 bound, 0 overload sets, 0 open
