// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
//
// IMPORTS.md §2.1: a pinned library. `geometry/module.k` says `module geo`,
// so that directory is the root of library `geo`: it is imported by the
// DECLARED name, and every file under it is `geo::<dirs>::<stem>`, never
// `geometry::...`. `tools/module.k` pins the two-segment `acme::tools`.
//
// Found because they sit in an immediate subdirectory of a search root (here
// the cwd, which lit sets to this directory); no -I is involved.

import geo
import geo::shapes
import geo::inner::deep
import acme::tools::hammer

fn use_all() -> i32 {
    return shapes::area() + deep::depth() + hammer::swing() + geo::shapes::area()
}

// DIAG-NOT: error

// --- imported by the declared name, and the module IS that name -----------
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}module_pins/main.k =====
// SEMA:      use     shapes {{.*}} -> module shapes {{.*}}  [import overlay]
// SEMA-NEXT: member  ::area  {{.*}} -> fn area @ 7:5
// SEMA:      use     deep {{.*}} -> module deep {{.*}}  [import overlay]
// SEMA:      use     hammer {{.*}} -> module hammer {{.*}}  [import overlay]
// SEMA:      use     geo {{.*}} -> module geo {{.*}}  [import overlay]
// SEMA: 0 unresolved

// --- module paths: the pin's name, then the directories below it ----------
// CXX-DAG: namespace geo::shapes {
// CXX-DAG: namespace geo::inner::deep {
// CXX-DAG: namespace acme::tools::hammer {
// CXX-NOT: namespace geometry
