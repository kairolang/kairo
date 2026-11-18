// build.py --single --target T compares the fork commit T's cross LLVM was
// built from (its VCSRevision.h, or a CI archive's PREBUILT) with the one
// the tree pins. When they differ it says so in one line, then: --stale-llvm
// decides without asking; otherwise a terminal is asked whether to rebuild
// LLVM or link with the built one (Enter links), and a run without a
// terminal links with the built one. inputs/build_stale_llvm/check.py runs
// the rule on fake cross trees; nothing is built.

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: python3 %S/inputs/build_stale_llvm/check.py %S/../../.. %t.d | %FileCheck %s
// CHECK: built 8f7e268535dd8e82207b41a07a7fb685e7a79e1b
// CHECK-NEXT: prebuilt a47beecca7198bb65cc363bb2e674fdc68bd42ce
// CHECK-NEXT: none ''
// CHECK-NEXT: fresh: use
// CHECK-NEXT: unknown: use
// CHECK-NEXT: warning: the cross LLVM for x86_64-linux-musl was built at commit 8f7e268535dd, the tree pins a47beecca719 (build/cross-llvm/x86_64-linux-musl)
// CHECK-NEXT: flag use: use
// CHECK-NEXT: warning: the cross LLVM
// CHECK-NEXT: flag rebuild: rebuild
// CHECK-NEXT: warning: the cross LLVM
// CHECK-NEXT: no terminal: use
// CHECK-NEXT: warning: the cross LLVM
// CHECK-NEXT: asked: rebuild LLVM for x86_64-linux-musl, or link with the built one? [r/L]
// CHECK-NEXT: enter: use
// CHECK-NEXT: warning: the cross LLVM
// CHECK-NEXT: asked: rebuild LLVM
// CHECK-NEXT: r: rebuild
// CHECK-NEXT: warning: the cross LLVM
// CHECK-NEXT: asked: rebuild LLVM
// CHECK-NEXT: eof: use
// CHECK-NOT: NOT ASKED
