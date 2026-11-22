// One object cache serves several programs, so a TU's object must depend
// on the TU alone, never on the graph it was compiled in: its key is the
// TU's own. holder.k defines a static field with a dynamic initializer.
// Its inline definition is one clang emits in every TU that sees it, used
// or not. Under the interface PCH, which holds every TU's interface, the
// definition must stay out of the PCH: otherwise plain.k's object, compiled
// in both.k's graph, references holder.k's initializer thunk, and only.k,
// whose graph has no holder.k, reuses that object and cannot link it.
//
// The second run reuses the objects the first stored, links and runs, and
// plain.k's object is byte-identical to one compiled in only.k's graph
// alone.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %t.d && %kairo -I %S/inputs/iface_pch_static %S/inputs/iface_pch_static/both.k -o %t.d/a1 --cache-dir %t.d/c --interface-pch=on --print-stats 2>&1 | %FileCheck %s --check-prefix=ONE
// ONE: [stats] incremental: 0 reused, {{[0-9]+}} compiled, {{[0-9]+}} stored
// RUN: %t.d/a1; test $? -eq 7
// RUN: cd %t.d && { %kairo -I %S/inputs/iface_pch_static %S/inputs/iface_pch_static/only.k -o %t.d/a2 --cache-dir %t.d/c --interface-pch=on --print-stats 2>&1 || true; } | %FileCheck %s --check-prefix=TWO
// TWO-NOT: error [
// TWO: [stats] incremental: {{[1-9][0-9]*}} reused,
// TWO-NOT: error [
// RUN: %t.d/a2; test $? -eq 8
// RUN: cd %t.d && %kairo -I %S/inputs/iface_pch_static %S/inputs/iface_pch_static/only.k -o %t.d/a3 --cache-dir %t.d/fresh --interface-pch=on
// RUN: %t.d/a3; test $? -eq 8
// RUN: cmp %t.d/c/plain.o %t.d/fresh/plain.o
