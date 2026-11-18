// Incremental Sema and a conditional extension. bridge.k's extension of
// `string` exists only in a file that declares `cxx::std::string`. main.k
// imports a header that does not: passing a `string` where a `std::string`
// is wanted is an error. The conversion appears when that header gains
// `#include <string>`, with no `.k` file edited, and goes when it loses
// it; the same when main.k gains and loses an import of a header that has
// it. The process is kept alive between the steps. A changed header and a
// changed set of C++ imports are both full checks, so the file's answer is
// asked again. Every step equals a fresh run
// (Scripts/incr_replay_check.py): the same diagnostics and the same
// interface dump.

// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d/p && cp -r %S/inputs/gated %t.d/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.d/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --script %S/inputs/gated.replay --scratch %t.d/scratch | %FileCheck %s --implicit-check-not=DIFFERS

// CHECK: step 1 use_without_string: refresh {{.*}} ok
// CHECK: step 2 header_gains_string: full (a C or C++ header) {{.*}} ok
// CHECK: step 3 body_edit: refresh {{.*}} ok
// CHECK: step 4 header_loses_string: full (a C or C++ header) {{.*}} ok
// CHECK: step 5 add_import: full (a C or C++ import was added or removed) {{.*}} ok
// CHECK: step 6 remove_import: full (a C or C++ import was added or removed) {{.*}} ok
// CHECK: modes: full 5, refresh 2; 7 steps
//
// The live process's own diagnostics: one error at each step where the
// file does not declare the type (1, 4 and 6), and none at the others.
// RUN: %FileCheck %s --check-prefix=LIVE --input-file=%t.d/scratch/live.stderr --implicit-check-not="error ["
// LIVE: main.k:6:12: error [SC063E]: no matching overload for call to 'lib_takes'
// LIVE: main.k:6:12: error [SC063E]: no matching overload for call to 'lib_takes'
// LIVE: main.k:6:12: error [SC063E]: no matching overload for call to 'lib_takes'
