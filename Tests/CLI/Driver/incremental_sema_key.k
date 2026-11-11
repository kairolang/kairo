// Incremental Sema, phase 2 (Compiler/Spec/IncrementalSema.md#phase-2): the
// parts of the key that are not source files, and when a run is not
// eligible at all. Type-check-only runs, which record and hit like a
// linking run (with no objects).

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/../../Sema/Incremental/Inputs/records %t.d/s
//
// Not eligible: no --cache-dir; a dump flag.
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=NOCACHE
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --print-incr-status --print-sema | %FileCheck %s --check-prefix=DUMP
// NOCACHE: incremental: miss: not eligible (no --cache-dir)
// DUMP: incremental: miss: not eligible (a print or dump flag)
//
// The environment switch, and a type-check-only hit replaying the warning.
// RUN: cd %t.d && env KAIRO_INCR_SEMA=1 %kairo -I s s/main.k --type-check-only --cache-dir c --print-incr-status > o1 2> e1
// RUN: cd %t.d && env KAIRO_INCR_SEMA=1 %kairo -I s s/main.k --type-check-only --cache-dir c --print-incr-status > o2 2> e2
// RUN: %FileCheck %s --check-prefix=MISS0 --input-file=%t.d/o1
// RUN: %FileCheck %s --check-prefix=HIT --input-file=%t.d/o2
// RUN: cmp %t.d/e1 %t.d/e2
// RUN: %FileCheck %s --check-prefix=WARN --input-file=%t.d/e2
// MISS0: incremental: miss: no record
// HIT: incremental: hit, {{[1-9][0-9]*}} modules
// WARN: util.k:2:13: warning [SC031W]
//
// An environment variable that steers the run.
// RUN: cd %t.d && env KAIRO_INCR_TEST=1 %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=ENV
// RUN: cd %t.d && env KAIRO_INCR_TEST=1 %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=HIT
// ENV: incremental: miss: environment changed
//
// The compiler executable changing, through the test hook that names a
// stand-in file for it.
// RUN: echo one > %t.d/exe
// RUN: cd %t.d && env KAIRO_INCR_TEST=1 KAIRO_INCR_TEST_EXE=%t.d/exe %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=EXE
// RUN: cd %t.d && env KAIRO_INCR_TEST=1 KAIRO_INCR_TEST_EXE=%t.d/exe %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=HIT
// RUN: echo two > %t.d/exe
// RUN: cd %t.d && env KAIRO_INCR_TEST=1 KAIRO_INCR_TEST_EXE=%t.d/exe %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=EXE
// RUN: cd %t.d && env KAIRO_INCR_TEST=1 KAIRO_INCR_TEST_EXE=%t.d/exe %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --print-incr-status --incr-paranoid | %FileCheck %s --check-prefix=HIT
// EXE: incremental: miss: compiler changed: {{.*}}exe
//
// A builtin file changing: a copy of the builtin tree (and the runtime
// headers it includes beside it), edited.
// RUN: mkdir -p %t.d/L && cp -r %S/../../../Lib/builtin %S/../../../Lib/rt %t.d/L
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --builtins-dir=%t.d/L/builtin --cache-dir c2 --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=MISS0
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --builtins-dir=%t.d/L/builtin --cache-dir c2 --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=HIT
// RUN: echo '// edited' >> %t.d/L/builtin/module.k
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --builtins-dir=%t.d/L/builtin --cache-dir c2 --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=BUILTIN
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --builtins-dir=%t.d/L/builtin --cache-dir c2 --incremental-sema --print-incr-status --incr-verify | %FileCheck %s --check-prefix=VERIFIED
// BUILTIN: incremental: miss: changed: {{.*}}/L/builtin/module.k
// VERIFIED: incremental: hit, {{[1-9][0-9]*}} modules, verified
