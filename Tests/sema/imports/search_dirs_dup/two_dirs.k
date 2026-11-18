// RUN: { %kairo %s --type-check-only -I %S/inputs/one -I %S/inputs/two 2>&1 || true; } | %FileCheck %s
//
// main.k's rule between two -I dirs: `inputs/one/b.k` and `inputs/two/b.k`
// are both module `b`, and the first -I does not win.

import b

fn use_b() -> i32 { return 0 }

// CHECK: two_dirs.k:6:{{[0-9]+}}: error [R017E]: ambiguous import 'b'
// CHECK-SAME: inputs/one/b.k
// CHECK-SAME: inputs/two/b.k
