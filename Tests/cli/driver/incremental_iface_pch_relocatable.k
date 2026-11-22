// One object cache serves several programs, so a TU's object must depend
// on the TU alone, never on the graph it was compiled in. Callee.k takes
// Meta, a struct holding a `@relocatable` string, by value. Whether clang
// passes Meta by value or through a pointer must not depend on where the
// graph's streams put string's move constructor: One.k's graph has Aaa.k,
// whose stream comes first in its interface PCH and defines that
// constructor before any stream defines Meta; Two.k's graph does not.
//
// The second run reuses Callee.k's object from the first, links it with
// Two.k's, compiled in its own graph, and runs (a pointer where the caller
// passes the bytes crashes); and the reused object is byte-identical to one
// compiled in Two.k's graph alone.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %t.d && %kairo -I %S/inputs/iface_pch_relocatable %S/inputs/iface_pch_relocatable/One.k -o %t.d/a1 --cache-dir %t.d/c --interface-pch=on --print-stats 2>&1 | %FileCheck %s --check-prefix=ONE
// ONE: [stats] incremental: 0 reused, {{[0-9]+}} compiled, {{[0-9]+}} stored
// RUN: %t.d/a1; test $? -eq 16
// RUN: cd %t.d && { %kairo -I %S/inputs/iface_pch_relocatable %S/inputs/iface_pch_relocatable/Two.k -o %t.d/a2 --cache-dir %t.d/c --interface-pch=on -v 2>&1 || true; } | %FileCheck %s --check-prefix=TWO
// TWO-NOT: error [
// TWO: incremental: reused Callee (
// TWO-NOT: error [
// RUN: %t.d/a2; test $? -eq 15
// RUN: cd %t.d && %kairo -I %S/inputs/iface_pch_relocatable %S/inputs/iface_pch_relocatable/Two.k -o %t.d/a3 --cache-dir %t.d/fresh --interface-pch=on
// RUN: %t.d/a3; test $? -eq 15
// RUN: cmp %t.d/c/Callee.o %t.d/fresh/Callee.o
