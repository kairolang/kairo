// What the Sema agreement walk of an interface PCH covers is part of the
// cache key of the TU that carries the findings of PCH bodies in files that
// are no TU of the PCH: the first TU of the PCH by module path. Two graphs
// that share that TU but not the rest of the PCH's TUs keep one object
// each for it. Every other TU's key is the same in both graphs.
//
// inputs/pch_walk: aaa.k sorts first; z1.k and z2.k are two entries that
// import it.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
//
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/inputs/pch_walk %t.d/s
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/z1.k -o %t.d/a -v -fsema-agreement --interface-pch=on --cache-dir %t.d/c 2>&1 | %FileCheck %s --check-prefix=Z1
// Z1: incremental: compiling aaa (not cached)
//
// Another graph: aaa compiles under the walk of another set of TUs.
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/z2.k -o %t.d/b -v -fsema-agreement --interface-pch=on --cache-dir %t.d/c 2>&1 | %FileCheck %s --check-prefix=Z2
// Z2: incremental: compiling aaa (changed: iface-walk)
//
// Each graph's object is kept: the first graph reuses its own.
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/z1.k -o %t.d/a -v -fsema-agreement --interface-pch=on --cache-dir %t.d/c 2>&1 | %FileCheck %s --check-prefix=AGAIN
// AGAIN: incremental: reused aaa
//
// Without the walk the key has no such line, and the graphs share aaa.
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/z1.k -o %t.d/a -v -fno-sema-agreement --interface-pch=on --cache-dir %t.d/c2 2>&1 | %FileCheck %s --check-prefix=Z1
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/z2.k -o %t.d/b -v -fno-sema-agreement --interface-pch=on --cache-dir %t.d/c2 2>&1 | %FileCheck %s --check-prefix=OFF
// OFF: incremental: reused aaa
