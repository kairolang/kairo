// Incremental Sema, the re-check plan: two entries over the same modules
// that share a cache directory (as build.py's targets do) keep their plan
// records apart. The
// plan of run A is evaluated over the rows A stored, not over what run B
// wrote for the same modules after an edit A has not seen: with one record
// per module, A's plan after the edit below was `geo` alone, "verified"
// against B's post-edit records, and main (which the edit breaks) was left
// out.

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d/x && cp -r %S/Inputs/plan %t.d/s && cp %t.d/s/main.k %t.d/x/main2.k
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema > /dev/null 2>&1 || true; }
// RUN: cd %t.d && { %kairo -I s x/main2.k --type-check-only --cache-dir c --incremental-sema > /dev/null 2>&1 || true; }
// RUN: sed -e 's/sum(p: Point) -> i32/sum(p: Point, k: i32) -> i32/' %t.d/s/geo.k > %t.d/u && mv %t.d/u %t.d/s/geo.k
// RUN: cd %t.d && { %kairo -I s x/main2.k --type-check-only --cache-dir c --incremental-sema > /dev/null 2>&1 || true; }
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --input-file=%t.d/o
// CHECK: incremental: plan: re-check 2 of {{[0-9]+}} modules
// CHECK-NEXT: incremental: plan: geo: R0 edited
// CHECK-NEXT: incremental: plan: main: R1 name sum in geo#<file>
// CHECK-NEXT: incremental: plan: verified
