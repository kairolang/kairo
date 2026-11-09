// Incremental compilation, phase 1 (Compiler/Spec/Incremental.md#the-interface):
// a change to what a dependent can see regenerates the file and exactly the
// dependents that use the changed entry; one to an entry no dependent uses
// regenerates the file alone. Each step's binary is byte-identical to a clean
// build of the same tree. util.k is imported by main.k only, so "2 compiled"
// is util and main.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/Inputs/incremental %t.d/s
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a0 --cache-dir %t.d/c -finfer-purity
//
// A signature main never names: util alone.
// RUN: sed -e 's/fn unused(x: i32) -> i32/fn unused(x: i64) -> i64/' %t.d/s/util.k > %t.d/u && mv %t.d/u %t.d/s/util.k
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a1 --cache-dir %t.d/c -finfer-purity --print-stats -v 2>&1 | %FileCheck %s --check-prefix=UNUSED
// UNUSED-NOT: incremental: compiling main
// UNUSED: [stats] incremental: {{[1-9][0-9]*}} reused, 1 compiled, 1 stored
// RUN: rm -rf %t.d/f && cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a1c --cache-dir %t.d/f -finfer-purity && cmp %t.d/a1 %t.d/a1c
//
// A signature main calls (a default argument, which the call site evaluates).
// RUN: sed -e 's/fn calc(x: i32) -> i32 { return x \* 3 }/fn calc(x: i32, y: i32 = 1) -> i32 { return x * 3 + y }/' %t.d/s/util.k > %t.d/u && mv %t.d/u %t.d/s/util.k
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a2 --cache-dir %t.d/c -finfer-purity --print-stats -v 2>&1 | %FileCheck %s --check-prefix=USED
// USED: incremental: compiling main
// USED: [stats] incremental: {{[1-9][0-9]*}} reused, 2 compiled, 2 stored
// RUN: rm -rf %t.d/f && cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a2c --cache-dir %t.d/f -finfer-purity && cmp %t.d/a2 %t.d/a2c
// RUN: %t.d/a2; test $? -eq 9
//
// A private field: main allocates and copies a Box, so its layout is main's too.
// RUN: sed -e 's|// FIELD|priv var c: i64 = 0|' %t.d/s/util.k > %t.d/u && mv %t.d/u %t.d/s/util.k
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a3 --cache-dir %t.d/c -finfer-purity --print-stats 2>&1 | %FileCheck %s --check-prefix=TWO
// TWO: [stats] incremental: {{[1-9][0-9]*}} reused, 2 compiled, 2 stored
// RUN: rm -rf %t.d/f && cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a3c --cache-dir %t.d/f -finfer-purity && cmp %t.d/a3 %t.d/a3c
//
// A generic body: main instantiates ident<i32>, so the body is compiled into it.
// RUN: sed -e 's/{ return x }/{ var y = x; return y }/' %t.d/s/util.k > %t.d/u && mv %t.d/u %t.d/s/util.k
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a4 --cache-dir %t.d/c -finfer-purity --print-stats 2>&1 | %FileCheck %s --check-prefix=TWO
// RUN: rm -rf %t.d/f && cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a4c --cache-dir %t.d/f -finfer-purity && cmp %t.d/a4 %t.d/a4c
//
// An inferred fact: calc stops being `const` (it writes G), and main's
// declaration of it loses the attribute, though no signature changed.
// RUN: sed -e 's/{ return x \* 3 + y }/{ G = x; return x * 3 + y }/' %t.d/s/util.k > %t.d/u && mv %t.d/u %t.d/s/util.k
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a5 --cache-dir %t.d/c -finfer-purity --print-stats 2>&1 | %FileCheck %s --check-prefix=TWO
// RUN: rm -rf %t.d/f && cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a5c --cache-dir %t.d/f -finfer-purity && cmp %t.d/a5 %t.d/a5c
// RUN: %t.d/a5; test $? -eq 9
