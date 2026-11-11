// Incremental Sema, the re-check plan (Compiler/Spec/IncrementalSema.md,
// "Phase 3"): after a miss, the compiler evaluates the dependency rows the
// previous run stored against this run's interfaces and prints which modules
// had to be re-checked and by which rule (--print-incr-plan). Nothing is
// reused on the plan's strength: every step below is a full run, and
// --incr-verify proves the plan against it (each module left out has the
// interface and the diagnostics of its record). Each step's diagnostics are
// also compared with a run that has no switch at all.
//
// Inputs/plan has one deliberate error (use_hidden.k calls a private
// function), so its records are written by a run with an error, and its note
// into hidden.k is what R8 is about.

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/Inputs/plan %t.d/s
//
// No record: every module. Then nothing changed: none, and every record holds.
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=NONE --input-file=%t.d/o
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only > /dev/null 2> clean || true; }
// RUN: cmp %t.d/e %t.d/clean
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan --print-incr-status > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=SAME --input-file=%t.d/o
// RUN: cmp %t.d/e %t.d/clean
// NONE: incremental: plan: re-check all {{[0-9]+}} modules (no record)
// SAME: incremental: miss: the recorded run had errors
// SAME: incremental: plan: re-check 0 of {{[0-9]+}} modules
// SAME: incremental: plan: verified, {{[0-9]+}} modules as recorded
//
// A body edit of a plain function: its file alone.
// RUN: sed -e 's/return y \* 3/return 3 * y/' %t.d/s/util.k > %t.d/u && mv %t.d/u %t.d/s/util.k
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=BODY --input-file=%t.d/o
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only > /dev/null 2> clean || true; }
// RUN: cmp %t.d/e %t.d/clean
// BODY: incremental: plan: re-check 1 of {{[0-9]+}} modules
// BODY-NEXT: incremental: plan: util: R0 edited
// BODY-NEXT: incremental: plan: verified
//
// A signature edit: the file and the one reader of the name.
// RUN: sed -e 's/sum(p: Point) -> i32/sum(p: Point, k: i32 = 0) -> i32/' %t.d/s/geo.k > %t.d/u && mv %t.d/u %t.d/s/geo.k
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=SIG --input-file=%t.d/o
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only > /dev/null 2> clean || true; }
// RUN: cmp %t.d/e %t.d/clean
// SIG: incremental: plan: re-check 2 of {{[0-9]+}} modules
// SIG-NEXT: incremental: plan: geo: R0 edited
// SIG-NEXT: incremental: plan: main: R1 name sum in geo#<file>
// SIG-NEXT: incremental: plan: verified
//
// A private field's type: the readers of the type (its I is its layout).
// RUN: sed -e 's/priv var n: i32 = 0/priv var n: i64 = 0/' %t.d/s/counter.k > %t.d/u && mv %t.d/u %t.d/s/counter.k
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=FIELD --input-file=%t.d/o
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only > /dev/null 2> clean || true; }
// RUN: cmp %t.d/e %t.d/clean
// FIELD: incremental: plan: re-check 2 of {{[0-9]+}} modules
// FIELD-NEXT: incremental: plan: counter: R0 edited
// FIELD-NEXT: incremental: plan: use_counter: R1 name Counter in counter#<file>
// FIELD-NEXT: incremental: plan: verified
//
// A generic's body: whoever instantiates it.
// RUN: sed -e 's/    return v/    var w = v; return w/' %t.d/s/gen.k > %t.d/u && mv %t.d/u %t.d/s/gen.k
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=GEN --input-file=%t.d/o
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only > /dev/null 2> clean || true; }
// RUN: cmp %t.d/e %t.d/clean
// GEN: incremental: plan: re-check 2 of {{[0-9]+}} modules
// GEN-NEXT: incremental: plan: gen: R0 edited
// GEN-NEXT: incremental: plan: use_gen: R3 body of gen#fn:twice<1>(T)
// GEN-NEXT: incremental: plan: verified
//
// A declaration added that nothing looked up, then removed: the file alone.
// RUN: sed -e 's|^// SLOT|pub fn area(p: Point) -> i32 = p.x * p.y|' %t.d/s/geo.k > %t.d/u && mv %t.d/u %t.d/s/geo.k
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=DECL --input-file=%t.d/o
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only > /dev/null 2> clean || true; }
// RUN: cmp %t.d/e %t.d/clean
// RUN: sed -e 's|^pub fn area.*$|// SLOT|' %t.d/s/geo.k > %t.d/u && mv %t.d/u %t.d/s/geo.k
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=DECL --input-file=%t.d/o
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only > /dev/null 2> clean || true; }
// RUN: cmp %t.d/e %t.d/clean
// DECL: incremental: plan: re-check 1 of {{[0-9]+}} modules
// DECL-NEXT: incremental: plan: geo: R0 edited
// DECL-NEXT: incremental: plan: verified
//
// A line added above a declaration another file's diagnostic points at: no
// interface moves, but the recorded note has the old line (R8).
// RUN: sed -e '1s|^|// moved down\n|' %t.d/s/hidden.k > %t.d/u && mv %t.d/u %t.d/s/hidden.k
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=SHIFT --input-file=%t.d/o
// RUN: %FileCheck %s --check-prefix=NOTE --input-file=%t.d/e
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only > /dev/null 2> clean || true; }
// RUN: cmp %t.d/e %t.d/clean
// SHIFT: incremental: plan: re-check 2 of {{[0-9]+}} modules
// SHIFT-NEXT: incremental: plan: hidden: R0 edited
// SHIFT-NEXT: incremental: plan: use_hidden: R8 its diagnostics name a position in {{.*}}hidden.k
// SHIFT-NEXT: incremental: plan: verified
// NOTE: hidden.k:2:9: note [R047N]
//
// What the rows cannot see is every module: a C header, a flag.
// RUN: sed -e 's/return 2;/return 1 + 1;/' %t.d/s/hdr.h > %t.d/u && mv %t.d/u %t.d/s/hdr.h
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=HDR --input-file=%t.d/o
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan -O1 > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=FLAG --input-file=%t.d/o
// HDR: incremental: plan: re-check all {{[0-9]+}} modules (changed: {{.*}}hdr.h)
// FLAG: incremental: plan: re-check all {{[0-9]+}} modules (flags changed)
//
// A file added beside the graph's: a graph change, every module.
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema > /dev/null 2>&1 || true; }
// RUN: echo 'pub fn extra() -> i32 = 1' > %t.d/s/extra.k
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=GRAPH --input-file=%t.d/o
// GRAPH: incremental: plan: re-check all {{[0-9]+}} modules (graph changed: {{.*}})
//
// The proof has teeth: with main's rows on geo taken out of its record, an
// edit of geo that breaks main is a module the plan leaves out and the full
// run changes. The run fails and the records stay.
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema > /dev/null 2>&1 || true; }
// RUN: grep -lx 'module main' %t.d/c/kairo-cache-v*/mod/*.plan > %t.d/which
// RUN: grep -v '^[ND].*geo' `cat %t.d/which` > %t.d/u && cp %t.d/u `cat %t.d/which`
// RUN: sed -e 's/sum(p: Point, k: i32 = 0) -> i32/sum(p: Point, k: i32) -> i32/' %t.d/s/geo.k > %t.d/u && mv %t.d/u %t.d/s/geo.k
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=HOLE --input-file=%t.d/o
// RUN: %FileCheck %s --check-prefix=HOLE-ERR --input-file=%t.d/e
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=HOLE --input-file=%t.d/o
// HOLE: incremental: plan: re-check 1 of {{[0-9]+}} modules
// HOLE: incremental: plan: verify FAILED: main: predicted unaffected, but its diagnostics changed
// HOLE-ERR: error [U001E]: --incr-verify: the dependency rows leave a module out of the re-check set
