// IMPORTS.md §2.1: a file's module path is a property of the FILE. A pinned
// module.k names every file below it, found by walking UP from the file --
// past the cwd and past any -I dir that holds it -- so the same file is the
// same module, and the same C++ namespace, whoever compiles it from
// wherever. Inputs/module_walkup/geometry/module.k says `module geo`, and no
// search root of any run below registers that directory as a library.
//
// The walk used to stop at the deepest search root holding the file: from
// inside geometry/inner, or through `-I geometry/inner`, x.k was `namespace
// x`, while every importer above the library calls `geo::inner::x`, so a
// `kcc -c` run from inside a library defined symbols nothing links against
// (Kcc/kcc_library_paths.k links them).

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d

// From inside the library: the cwd is geometry/inner, which has no pin.
// Its files import their own library by name and by the path as written.
// RUN: cd %S/Inputs/module_walkup/geometry/inner && %kairo x.k r.k --type-check-only
// RUN: cd %S/Inputs/module_walkup/geometry/inner && %kairo x.k r.k --type-check-only --print-cxx 2>&1 | %FileCheck %s --check-prefix=INSIDE
// INSIDE-DAG: namespace geo::inner::x {
// INSIDE-DAG: namespace geo::inner::r {
// INSIDE-DAG: namespace geo::shapes {
// INSIDE-NOT: namespace x {

// Through an -I dir below the pin, from a cwd that does not discover the
// library (geometry is two levels down from it).
// RUN: cd %S/Inputs && %kairo module_walkup/m2.k -I module_walkup/geometry/inner --type-check-only --print-cxx 2>&1 | %FileCheck %s --check-prefix=VIA_I
// VIA_I: namespace geo::inner::x {
// VIA_I-NOT: namespace x {

// From a directory outside every search root and the library.
// RUN: cd %t.d && %kairo %S/Inputs/module_walkup/geometry/shapes.k --type-check-only --print-cxx 2>&1 | %FileCheck %s --check-prefix=OUTSIDE
// OUTSIDE: namespace geo::shapes {
// OUTSIDE-NOT: namespace shapes {

// A library file never falls back into an unnamed search dir, and that holds
// for a library found walking up exactly as for a registered one: which
// library holds a file does not depend on the run. leak.k's `import helper`
// is only on `-I walkup_helper`.
// RUN: cd %S/Inputs && { %kairo module_walkup/geometry/inner/leak.k -I walkup_helper --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=LEAK
// LEAK: leak.k:3:1: error [R011E]: failed to resolve import path 'helper'
