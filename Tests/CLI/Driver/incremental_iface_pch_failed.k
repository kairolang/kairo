// The object cache stores a TU under the key it was computed with, and the
// key says whether the TU compiles under the interface PCH
// (CodegenJob::iface_on), since the objects differ. Here the PCH's one
// stream fails: ma.k and mb.k give one C function two types, which only a
// stream holding both TUs sees. Every TU of that flavour then compiles
// without the PCH, and none may be stored under a key that says it had it.
// The second run, whose PCH fails the same way, compiles the three
// again instead of reusing objects their keys do not describe.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %t.d && %kairo -I %S/Inputs/iface_pch_failed %S/Inputs/iface_pch_failed/main.k -o %t.d/a1 --cache-dir %t.d/c --interface-pch=on --print-stats 2>&1 | %FileCheck %s --check-prefix=ONE
// ONE: [stats] incremental: 0 reused, {{[0-9]+}} compiled, {{[0-9]+}} stored
// RUN: %t.d/a1; test $? -eq 12
// RUN: cd %t.d && %kairo -I %S/Inputs/iface_pch_failed %S/Inputs/iface_pch_failed/main.k -o %t.d/a2 --cache-dir %t.d/c --interface-pch=on --print-stats 2>&1 | %FileCheck %s --check-prefix=TWO
// TWO: [stats] incremental: {{[0-9]+}} reused, 3 compiled, 0 stored
// RUN: %t.d/a2; test $? -eq 12
