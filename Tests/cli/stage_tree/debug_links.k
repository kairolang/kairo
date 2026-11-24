// Scripts/stage_tree.py bundles the shared libraries a Linux tree's binaries
// load. A debug tree links the ones that come from the LLVM build (libLLVM,
// libclang-cpp: hundreds of MB per tree) instead of copying them; a release
// tree copies them, so it stays relocatable. Restaging converts either way,
// and bundling never patches the linked LLVM build files.
// inputs/debug_links/check.py runs bundle_tree on small trees.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: host-linux, clang, ldd-patchelf
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: python3 %S/inputs/debug_links/check.py %S/../../../Scripts %t.d %clang_c | %FileCheck %s
// CHECK: debug: link {{.*}}llvm/lib/libkfake.so.1 (to the build); OK; acts ['linked']
// CHECK-NEXT: debug again: link {{.*}} (to the build); OK; acts []
// CHECK-NEXT: debug from copy: link {{.*}} (to the build); OK; acts ['linked']
// CHECK-NEXT: debug alias: link {{.*}} (to the build); OK; acts []
// CHECK-NEXT: alias: libkfake.so.1
// CHECK-NEXT: release: copy; OK; acts ['bundled']
// CHECK-NEXT: debug as release: copy; OK; acts ['bundled']
// CHECK-NEXT: alias: libkfake.so.1
// CHECK-NEXT: llvm build unchanged: True
