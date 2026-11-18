// A C++ host named by a relative path that climbs with `..` (or carries
// `./`) is the same file as when it is named from its own directory: the
// `.k` it includes gets the same module path, so the host's `cells::...`
// names resolve. The host and its `.k` sit outside the working directory,
// which makes the `.k` a pathless module named after its file (`cells`);
// a spelling that kept the `..` would have put it under the working
// directory as `__::proj::cells`.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d/proj %t.d/work/deep
// RUN: cp %S/inputs/null_host/cells.k %S/inputs/null_host/null_main.cpp %t.d/proj/
// RUN: cd %t.d/work/deep && %kcc ../../proj/null_main.cpp -o %t.d/dotdot
// RUN: %t.d/dotdot | %FileCheck %s --match-full-lines
// RUN: cd %t.d/work/deep && %kcc ./.././../proj/./null_main.cpp -o %t.d/dotted
// RUN: %t.d/dotted | %FileCheck %s --match-full-lines
// RUN: cd %t.d/work && %kcc deep/../../proj/null_main.cpp -o %t.d/down_up
// RUN: %t.d/down_up | %FileCheck %s --match-full-lines
// RUN: cd %t.d/proj && %kcc ./null_main.cpp -o %t.d/here
// RUN: %t.d/here | %FileCheck %s --match-full-lines
// CHECK:      a null 1, b 4
// CHECK-NEXT: or_zero 0 4
// CHECK-NEXT: some 6, none null 1
// CHECK-NEXT: cell 3, d null 1
