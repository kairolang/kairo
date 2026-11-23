// Incremental Sema keys what the host CPU default resolved to
// (Compiler/Spec/IncrementalSema.md#phase-2): the command line does not
// spell the CPU a build for this machine targets, so the manifest's `f.cpu`
// part holds it. It differs between a run under the host default and a run
// for the baseline CPU, and a rerun on the same machine still hits.
//
// %kairo carries --mcpu=baseline; `--mcpu=` takes it back off.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: host-x86_64 || host-aarch64
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/../../sema/incremental/inputs/records %t.d/s
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --cache-dir base --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=MISS
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --cache-dir base --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=HIT
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --cache-dir host --incremental-sema --print-incr-status --mcpu= | %FileCheck %s --check-prefix=MISS
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --cache-dir host --incremental-sema --print-incr-status --mcpu= | %FileCheck %s --check-prefix=HIT
// MISS: incremental: miss: no record
// HIT:  incremental: hit, {{[1-9][0-9]*}} modules
// RUN: grep -h '^f\.cpu [0-9a-f]' %t.d/base/*/mod/run-*.txt > %t.d/base.cpu
// RUN: grep -h '^f\.cpu [0-9a-f]' %t.d/host/*/mod/run-*.txt > %t.d/host.cpu
// RUN: not cmp -s %t.d/base.cpu %t.d/host.cpu
