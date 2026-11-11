// Incremental Sema, phase 2 (Compiler/Spec/IncrementalSema.md#phase-2): a
// run whose every input is unchanged skips the frontend and links the
// recorded objects. Each step below is one run of the same command on
// Inputs/records (a warning in util.k, a C header, three modules): the
// second run is a hit with the first run's diagnostics and binary; each
// edit is a miss naming what changed, and the run after it hits again.
// --incr-verify runs the whole pipeline on a would-be hit and compares.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/Inputs/records %t.d/s
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status > o1 2> e1
// RUN: cp %t.d/a %t.d/a.first
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status > o2 2> e2
// RUN: %FileCheck %s --check-prefix=MISS0 --input-file=%t.d/o1
// RUN: %FileCheck %s --check-prefix=HIT --input-file=%t.d/o2
// RUN: %FileCheck %s --check-prefix=WARN --input-file=%t.d/e1
// RUN: cmp %t.d/e1 %t.d/e2
// RUN: cmp %t.d/a %t.d/a.first
// RUN: %t.d/a; test $? -eq 9
// MISS0: incremental: miss: no record
// HIT: incremental: hit, {{[1-9][0-9]*}} modules
// WARN: util.k:2:13: warning [SC031W]: redundant cast
//
// --incr-verify on the hit: the full run agrees with the records.
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status --incr-verify > o3 2> e3
// RUN: %FileCheck %s --check-prefix=VERIFIED --input-file=%t.d/o3
// RUN: cmp %t.d/e1 %t.d/e3
// VERIFIED: incremental: hit, {{[1-9][0-9]*}} modules, verified
//
// A touch without a change: the stat differs, the content does not.
// RUN: touch %t.d/s/util.k
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=HIT
//
// A body edit: a miss on util.k, a binary equal to a clean build, a hit after.
// RUN: sed -e 's/return y \* 3/return 3 * y/' %t.d/s/util.k > %t.d/u && mv %t.d/u %t.d/s/util.k
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=BODY
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=HIT
// RUN: cd %t.d && %kairo -I s s/main.k -o clean.bin --cache-dir clean1
// RUN: cmp %t.d/a %t.d/clean.bin
// BODY: incremental: miss: changed: {{.*}}s/util.k
//
// A signature edit.
// RUN: sed -e 's/sum(p: Point) -> i32/sum(p: Point, k: i32 = 0) -> i32/' -e 's/p.x + p.y$/p.x + p.y + k/' %t.d/s/shapes.k > %t.d/u && mv %t.d/u %t.d/s/shapes.k
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=SIG
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status --incr-verify | %FileCheck %s --check-prefix=VERIFIED
// RUN: %t.d/a; test $? -eq 9
// SIG: incremental: miss: changed: {{.*}}s/shapes.k
//
// A C header edit: no Kairo file changed.
// RUN: sed -e 's/return 2;/return 1 + 1;/' %t.d/s/hdr.h > %t.d/u && mv %t.d/u %t.d/s/hdr.h
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=HDR
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=HIT
// HDR: incremental: miss: changed: {{.*}}s/hdr.h
//
// A flag change, then back: two misses, then a hit.
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status -O1 | %FileCheck %s --check-prefix=FLAGS
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=FLAGS
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=HIT
// FLAGS: incremental: miss: flags changed
//
// A module file added beside the graph's (it could shadow or collide with
// an import), then removed: each a miss on the directory.
// RUN: echo 'pub fn extra() -> i32 = 1' > %t.d/s/extra.k
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=GRAPH
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=HIT
// RUN: rm %t.d/s/extra.k
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=GRAPH
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=HIT
// GRAPH: incremental: miss: graph changed: {{.*}}/s
//
// A file of the graph removed (and its import with it): the importer changed.
// RUN: sed -e 's/^import shapes$//' -e 's/shapes::sum(p)/3/' -e 's/var p = .*$//' %t.d/s/main.k > %t.d/u && mv %t.d/u %t.d/s/main.k && rm %t.d/s/shapes.k
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=MAIN
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=HIT
// RUN: %t.d/a; test $? -eq 9
// MAIN: incremental: miss: changed: {{.*}}s/main.k
//
// The object the link takes changed under the record: a miss, never a
// link of the wrong object.
// RUN: cp %t.d/a.first %t.d/c/util.o
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=OBJ
// RUN: cd %t.d && %kairo -I s s/main.k -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=HIT
// OBJ: incremental: miss: object changed: {{.*}}util.o
