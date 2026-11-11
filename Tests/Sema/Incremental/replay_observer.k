// Incremental Sema, phase 5: the observer a tool installs on a live check
// (Tooling::LiveCheck::observer, a Tooling::SemaObserver) is called for
// every file on a full check and for exactly the re-checked files on a
// refresh: on_checked at the checked tree, on_lowered after the lowerings.
// --incr-replay-observe prints the calls.

// RUN: rm -rf %t.d && mkdir -p %t.d/p && cp -r %S/Inputs/plan %t.d/p/s
// RUN: cd %t.d/p && %kairo s/main.k -I s --threads=2 --incr-replay-in-place --incr-replay-observe --incr-replay=%S/Inputs/plan.replay 2>/dev/null | %FileCheck %s

// The first check: every file of the graph.
// CHECK-DAG: checked util.k
// CHECK-DAG: checked geo.k
// CHECK-DAG: checked main.k
// CHECK: incr-replay: step 0 initial: full

// A body edit of util.k: util.k, use_util.k and main.k, and nothing else.
// CHECK-NOT: checked
// CHECK: checked util.k
// CHECK-NEXT: lowered util.k
// CHECK-NEXT: checked use_util.k
// CHECK-NEXT: lowered use_util.k
// CHECK-NEXT: checked main.k
// CHECK-NEXT: lowered main.k
// CHECK-NEXT: incr-replay: step 1 body: refresh (3 of 38 files)

// geo.k and its one importer.
// CHECK-NEXT: checked geo.k
// CHECK-NEXT: lowered geo.k
// CHECK-NEXT: checked main.k
// CHECK-NEXT: lowered main.k
// CHECK-NEXT: incr-replay: step 2 signature: refresh (2 of 38 files)
