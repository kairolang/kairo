class Buf { var n: i32; }
fn g(x: Buf) { }
fn g(@move x: Buf) { }                      // expect: error R001 cannot be overloaded on '@move'; note at line 2
fn h(x: Buf, y: Buf) { }
fn h(@inout x: Buf, @move y: Buf) { }       // expect: clean -- distinguishable by the marker on x

// --- lit wiring -----------------------------------------------------------
// KAIRO-ONLY: C++ accepts `g(Buf)` / `g(Buf&&)`; Kairo cannot choose between
// them because `@move` has no call-site marker (RedeclMerge::_check_move_overload).
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// DIAG:      move_overload.k:3:{{[0-9]+}}: error [R054E]: 'g' cannot be overloaded on '@move'
// DIAG-NEXT: move_overload.k:2:{{[0-9]+}}: note {{.*}}passing mode of 'x'
// DIAG-NOT:  error [
