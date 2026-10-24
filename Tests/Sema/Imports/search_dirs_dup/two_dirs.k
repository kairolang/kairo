// RUN: { %kairo %s --type-check-only -I %S/Inputs/one -I %S/Inputs/two 2>&1 || true; } | %FileCheck %s
//
// main.k's rule between two -I dirs: `Inputs/one/b.k` and `Inputs/two/b.k`
// are both module `b`, and the first -I does not win.

import b

fn use_b() -> i32 { return 0 }

// CHECK: two_dirs.k:6:{{[0-9]+}}: error [R017E]: ambiguous import 'b'
// CHECK-SAME: Inputs/one/b.k
// CHECK-SAME: Inputs/two/b.k
