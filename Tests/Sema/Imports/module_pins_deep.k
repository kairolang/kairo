// Decision E: one library name claimed from two places is an error, never a
// merge. Inputs/module_pins_deep/geometry/module.k pins `module geo` and is
// discovered (an immediate subdirectory of the cwd); vendor/g2/module.k pins
// `module geo` too, two levels down, where discovery never looks. Its files
// still take the pin's name (the walk up from each file), so main.k's
// `import vendor::g2::x` reached a second `geo::x`: two files, one module
// path, one C++ namespace and one object path, and the only symptom was a
// link error naming the wrong `geo::x::h`. A pinned directory found by the
// walk is checked like a registered one, and the two files are reported.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/module_pins_deep && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s
// RUN: cd %S/Inputs/module_pins_deep && not %kairo main.k --type-check-only > /dev/null 2>&1
// CHECK: error [R018E]: duplicate module root 'geo': '{{.*}}module_pins_deep/geometry' and '{{.*}}module_pins_deep/vendor/g2' both claim it
// CHECK: error [R018E]: '{{.*}}module_pins_deep/geometry/x.k' and '{{.*}}module_pins_deep/vendor/g2/x.k' are both module 'geo::x'
