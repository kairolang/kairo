// A C++ TU that includes two Kairo modules whose Panic results share an
// element type (i64) gets that type's id specialization (`__kairo_tid`)
// once: an include's token stream carries no guard, so the second include
// skips it by the record of the first (IncludedDecls::tid_seen). A kcc
// include writes no instantiation, but the host instantiates each Panic it
// uses, so the specializations come from the instances the include pruned.
// The host then reads the tags Kairo wrote: an Err's tag is its type's id,
// equal across both sets, and Ok is 0 (PANIC.md §1.1a, §1.3).

// REQUIRES: kcc
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc -Xkairo --test-panic-type %S/Inputs/panic_host/panic_main.cpp -o %t.d/app 2>&1 | { grep -E 'error|redefinition|warning' || true; } > %t.d/errs
// RUN: test ! -s %t.d/errs
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK: same 1 i64 1 i8 1 ok 1
