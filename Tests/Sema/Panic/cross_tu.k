// Panic sets across translation units (PANIC.md §2.2, RESOLUTION.md "The
// Typed barrier"). Inputs/cross_tu: lib.k infers its sets, main.k imports
// and calls them, broken.k stops in name resolution.
//
// - lib::parse's INFERRED set, {IOError, ParseError}, is final before
//   main.k is checked: a `try` catching only IOError leaves ParseError
//   unhandled, and a declared set holding both is accepted.
// - lib::safe handles everything, so calling it needs nothing.
// - broken.k never reached the barrier: its `panic` function's set is
//   unknown, and the call to it says nothing (no cascade from R020E).

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/cross_tu && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: broken.k:7:12: error [R020E]: use of undeclared identifier 'missing'
// CHECK: main.k:7:18: error [SC001E]: unhandled panic: 'parse' may panic with 'ParseError', and 'partial' is not marked 'panic'
// CHECK-NEXT: fix-it:"{{.*}}main.k":{6:19-6:19}:" panic"
// CHECK-NEXT: lib.k:13:5: note [SC001N]: 'parse' is declared 'panic' here
// CHECK-NEXT: main.k:7:18: note [SC001N]: or handle it here
// CHECK-NEXT: fix-it:"{{.*}}main.k":{7:18-7:18}:"try "
// CHECK-NEXT: fix-it:"{{.*}}main.k":{7:31-7:31}:" catch => crash!()"
