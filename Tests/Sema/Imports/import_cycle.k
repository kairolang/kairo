// An import cycle compiles, with a warning (R001W, placeholder) at the
// import that closes it: a cycle hinders maintainability. The warning is
// promoted by -Werror and silenced by -w like any other; -fno-import-cycles
// makes it an error (import_cycle_reject.k). Every file on a cycle is
// walked, typed with the others in lockstep (RESOLUTION.md, "The Typed
// barrier"), compiled and linked; macros are visible across the cycle in
// both directions, and a mutual `pub import` pair sees each other's
// transitive re-exports. Each case lives in Inputs/import_cycle/<case>/.
//
// Shapes: two files through the entry with mutual recursion, three files,
// a cycle with an importer outside it (no cycle through the entry), a file
// importing itself, a cycle through a `pub import`, generics called across a
// cycle, macros both ways, re-exports both ways through a mutual `pub import`
// pair, two disjoint cycles, and a type error inside a cycle.

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d

// The warning, in full.
// RUN: cd %S/Inputs/import_cycle/two && %kairo a.k --type-check-only 2>&1 | %FileCheck %s --check-prefix=WARN --implicit-check-not="error [" --implicit-check-not="warning ["
// WARN: b.k:2:1: warning [R001W]: import cycle: a.k -> b.k -> a.k; a cycle hinders maintainability: no module on it can be read, built or tested without the others
// WARN-NEXT: a.k:2:1: note [I900N]: 'a.k' imports 'b.k' here
// WARN-NEXT: b.k:2:1: note [I900N]: 'b.k' imports 'a.k' here
// WARN-NEXT: note [I900N]: move the declarations the modules share into a third module that each of them imports

// -Werror promotes it; -w silences it; -fimport-cycles is the default.
// RUN: cd %S/Inputs/import_cycle/two && not %kairo a.k -Werror --type-check-only 2>&1 | %FileCheck %s --check-prefix=WERROR
// WERROR: b.k:2:1: error [R001{{[WE]}}]: import cycle: a.k -> b.k -> a.k
// RUN: cd %S/Inputs/import_cycle/two && %kairo a.k -w --type-check-only 2>&1 | %FileCheck %s --check-prefix=QUIET --allow-empty
// QUIET-NOT: import cycle
// RUN: cd %S/Inputs/import_cycle/two && %kairo a.k -fimport-cycles --type-check-only 2>&1 | %FileCheck %s --check-prefix=WARN

// RUN: cd %S/Inputs/import_cycle/two && %kairo a.k -o %t.d/two.exe --cache-dir %t.d/c
// RUN: %t.d/two.exe; test $? -eq 45

// RUN: cd %S/Inputs/import_cycle/three && %kairo a.k -o %t.d/three.exe --cache-dir %t.d/c 2>&1 | %FileCheck %s --check-prefix=THREE
// THREE: c.k:2:1: warning [R001W]: import cycle: a.k -> b.k -> c.k -> a.k
// RUN: %t.d/three.exe; test $? -eq 13

// RUN: cd %S/Inputs/import_cycle/importer && %kairo main.k -o %t.d/importer.exe --cache-dir %t.d/c
// RUN: %t.d/importer.exe; test $? -eq 84

// RUN: cd %S/Inputs/import_cycle/self && %kairo s.k -o %t.d/self.exe --cache-dir %t.d/c 2>&1 | %FileCheck %s --check-prefix=SELF
// SELF: s.k:2:1: warning [R001W]: 's.k' imports itself; a cycle hinders maintainability
// SELF-NEXT: fix-it:"{{.*}}s.k":{2:1-2:{{[0-9]+}}}:""
// RUN: %t.d/self.exe; test $? -eq 7

// RUN: cd %S/Inputs/import_cycle/pub && %kairo main.k -o %t.d/pub.exe --cache-dir %t.d/c
// RUN: %t.d/pub.exe; test $? -eq 3

// RUN: cd %S/Inputs/import_cycle/generic && %kairo a.k -o %t.d/generic.exe --cache-dir %t.d/c
// RUN: %t.d/generic.exe; test $? -eq 14

// Each file expands a macro the other defines; b.k is walked first.
// RUN: cd %S/Inputs/import_cycle/macros && %kairo a.k -o %t.d/macros.exe --cache-dir %t.d/c
// RUN: %t.d/macros.exe; test $? -eq 33

// A mutual `pub import` pair, entered through each side: c.k is re-exported
// by b.k, e.k by a.k, and each must reach the other's importers.
// RUN: cd %S/Inputs/import_cycle/reexport && %kairo main.k -o %t.d/reexport.exe --cache-dir %t.d/c
// RUN: %t.d/reexport.exe; test $? -eq 7
// RUN: cd %S/Inputs/import_cycle/reexport && %kairo main2.k -o %t.d/reexport2.exe --cache-dir %t.d/c
// RUN: %t.d/reexport2.exe; test $? -eq 15

// RUN: cd %S/Inputs/import_cycle/disjoint && %kairo main.k -o %t.d/disjoint.exe --cache-dir %t.d/c 2>&1 | %FileCheck %s --check-prefix=DISJOINT
// DISJOINT-DAG: b.k:1:1: warning [R001W]: import cycle: a.k -> b.k -> a.k
// DISJOINT-DAG: d.k:1:1: warning [R001W]: import cycle: c.k -> d.k -> c.k
// RUN: %t.d/disjoint.exe; test $? -eq 33

// A type error in a file on the cycle is seen -- it used to vanish with the
// file -- and the exit is nonzero.
// RUN: cd %S/Inputs/import_cycle/error && not %kairo a.k --type-check-only 2>&1 | %FileCheck %s --check-prefix=ERR
// ERR: a.k:3:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
// ERR-NOT: never preprocessed
