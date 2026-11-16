// A header --emit-headers writes, and its prelude, is published whole: the
// second run over a changed source renames a new file over the old one, so
// a reader holding the old file (here, a hard link to it) keeps the old
// bytes and never sees a truncated or partly written header, and no
// temporary is left beside it. Driven by Inputs/emit_headers_atomic.py.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: python3 %S/Inputs/emit_headers_atomic.py %t.d -- %kairo | %FileCheck %s
// CHECK: header rewritten: yes
// CHECK-NEXT: old header link kept: yes
// CHECK-NEXT: old prelude link kept: yes
// CHECK-NEXT: temporaries left: none
