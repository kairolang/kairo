// A live check with re-checking in place switched off runs every edit as a
// full check, and the reason it prints says the mode is off: the in-place
// path is part of every build, so the reason names the setting, not a
// missing feature.

// RUN: rm -rf %t.d && mkdir -p %t.d/p && cp -r %S/Inputs/plan %t.d/p/s
// RUN: cd %t.d/p && { %kairo_bin --incr-replay=%S/Inputs/plan.replay s/main.k -I s --threads=2 2>&1 || true; } | %FileCheck %s

// CHECK: incr-replay: step 0 initial: full (the first check)
// CHECK: incr-replay: step 1 body: full (re-checking in place is off)
// CHECK-NOT: is not built
