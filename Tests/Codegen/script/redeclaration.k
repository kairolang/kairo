// XFAIL: *
// Waiting on the script plumbing (Compiler/Sema/SCRIPT.md): NameResolution
// already reports two top-level bindings of one name as R029E, but with no
// fix-it; the design wants one that renames the second. This test checks
// the fix-it, so it fails until that lands. When it XPASSes, delete the
// XFAIL line.
//
// In a script every top-level binding is a global, whatever keyword
// declares it: `var x` and `static x` are two definitions of one name.

import std::io::println

static count: i32 = 1
var count = 2
println(f"{count}")

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      redeclaration.k:14:1: error [R029E]: 'count' redefined
// DIAG-NEXT: fix-it:{{.*}}:{14:5-14:10}:"count2"
// DIAG:      redeclaration.k:13:1: note [R029N]: previous declaration of 'count' is here
