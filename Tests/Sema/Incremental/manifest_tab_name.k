// A module whose name holds a tab (the entry module is named after its file)
// keeps its own plan record across runs: the run manifest writes such a name
// as a JSON string and reads it back whole, so an edit of that file
// re-checks that module alone, as it does for any other name, rather than
// falling back to re-checking every module.

fn main() -> i32 { return 4 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// A file name cannot hold a tab on Windows.
// UNSUPPORTED: host-windows
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cp %s "%t.d/$(printf 'tab\there').k"
// RUN: cd %t.d && %kairo "$(printf 'tab\there').k" -o a --cache-dir c --incremental-sema
// RUN: sed -i.bak 's/return 4/return 5/' "%t.d/$(printf 'tab\there').k"
// RUN: cd %t.d && %kairo "$(printf 'tab\there').k" -o a --cache-dir c --incremental-sema --print-incr-plan --print-incr-status 2>&1 | %FileCheck %s
// CHECK: incremental: miss: changed:
// CHECK-NEXT: incremental: plan: re-check 1 of {{[0-9]+}} modules
// CHECK-NEXT: incremental: plan:   tab{{.}}here: R0 edited
// RUN: %t.d/a; test $? -eq 5
// Unchanged, the run hits and --incr-verify finds the recorded module rows,
// the tab-named one read back whole, equal to the ones this run builds.
// RUN: cd %t.d && %kairo "$(printf 'tab\there').k" -o a --cache-dir c --incremental-sema --incr-verify --print-incr-status 2>&1 | %FileCheck %s --check-prefix=VERIFY
// VERIFY: incremental: hit, {{[0-9]+}} modules, verified
