// `--march=native` and `--mcpu native` name whichever machine runs the
// compile, and the command line spells only `native`: Incremental Sema keys
// what they resolved to (TargetOptions::resolved_cpu) in the manifest's
// `f.cpu` part, so a cache directory carried to another machine does not
// replay. Each run's `f.cpu` differs from a baseline run's.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: host-x86_64 || host-aarch64
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/../../sema/incremental/inputs/records %t.d/s
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --cache-dir base --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=MISS
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --cache-dir march --incremental-sema --print-incr-status --march=native | %FileCheck %s --check-prefix=MISS
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --cache-dir march --incremental-sema --print-incr-status --march=native | %FileCheck %s --check-prefix=HIT
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --cache-dir mcpu --incremental-sema --print-incr-status --mcpu native | %FileCheck %s --check-prefix=MISS
// MISS: incremental: miss: no record
// HIT:  incremental: hit, {{[1-9][0-9]*}} modules
// RUN: grep -h '^f\.cpu [0-9a-f]' %t.d/base/*/mod/run-*.txt > %t.d/base.cpu
// RUN: grep -h '^f\.cpu [0-9a-f]' %t.d/march/*/mod/run-*.txt > %t.d/march.cpu
// RUN: grep -h '^f\.cpu [0-9a-f]' %t.d/mcpu/*/mod/run-*.txt > %t.d/mcpu.cpu
// RUN: not cmp -s %t.d/base.cpu %t.d/march.cpu
// RUN: not cmp -s %t.d/base.cpu %t.d/mcpu.cpu
