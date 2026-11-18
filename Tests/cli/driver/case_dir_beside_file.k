// A directory and a module file whose names differ only by case
// (`Output/` beside `output.k`, as lit's scratch directory sits beside a
// test) were reported P002E "two modules on Linux and one file on default
// macOS/Windows", though they are two entries on every filesystem. Only
// two files, or two directories, differ-by-case into one entry; those stay
// P002E.

// RUN: rm -rf %t.d && mkdir -p %t.d/Output %t.d/sub %t.d/two
// RUN: echo 'pub fn out() -> i32 { return 1 }' > %t.d/output.k
// RUN: echo 'pub fn h() -> i32 { return 3 }' > %t.d/sub/helper.k
// RUN: echo 'import helper::h' > %t.d/sub/main.k
// RUN: echo 'fn main() -> i32 { return h() }' >> %t.d/sub/main.k
// RUN: cd %t.d && %kairo -I sub sub/main.k -o %t.d/a --cache-dir %t.d/c 2>&1 | %FileCheck %s --check-prefix=MIXED --allow-empty
// RUN: %t.d/a; test $? -eq 3
// MIXED-NOT: P002E
// RUN: echo 'pub fn a() -> i32 { return 1 }' > %t.d/two/Mod.k
// RUN: echo 'pub fn b() -> i32 { return 2 }' > %t.d/two/mod.k
// RUN: echo 'import Mod::a' > %t.d/two/main.k
// RUN: echo 'fn main() -> i32 { return a() }' >> %t.d/two/main.k
// RUN: cd %t.d/two && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=FILES
// FILES: error [P002E]: 'Mod' and 'mod' in '{{.*}}two' differ only by case
