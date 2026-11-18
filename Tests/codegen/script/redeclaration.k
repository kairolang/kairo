// In a script every top-level binding is a global, whatever keyword
// declares it: `var x` and `static x` are two definitions of one name.
// NameResolution reports the second as R029E, with a fix-it renaming it to
// the first free `<name>N`: `total2` is taken, so the second `total` is
// offered `total3`. Only two FILE-scope bindings get the rename: two
// fields of one struct are the same error with no fix-it, since the
// rename may not be what was meant there.

import std::io::println

static count: i32 = 1
var count = 2
var total2 = 0
const total: i32 = 3
var total = 4
println(f"{count}")

struct Pair {
    var a: i32 = 0
    var a: i32 = 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      redeclaration.k:12:1: error [R029E]: 'count' redefined
// DIAG-NEXT: fix-it:{{.*}}:{12:5-12:10}:"count2"
// DIAG-NEXT: redeclaration.k:11:1: note [R029N]: previous declaration of 'count' is here
// DIAG:      redeclaration.k:15:1: error [R029E]: 'total' redefined
// DIAG-NEXT: fix-it:{{.*}}:{15:5-15:10}:"total3"
// DIAG-NEXT: redeclaration.k:14:1: note [R029N]: previous declaration of 'total' is here
// DIAG:      redeclaration.k:20:{{[0-9]+}}: error [R029E]: 'a' redefined
// DIAG-NOT:  fix-it
// DIAG:      redeclaration.k:19:{{[0-9]+}}: note [R029N]: previous declaration of 'a' is here
