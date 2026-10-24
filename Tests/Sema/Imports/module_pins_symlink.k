// One directory under two spellings is one library. b/geolink is a symlink
// to Inputs/module_walkup/geometry (`module geo`); the cwd's discovery finds
// it through the link, and -I names the real path. Roots used to be compared
// by the path as spelled, so the vendored link and the -I were two libraries
// both called `geo`: a false R018E before anything was parsed. Roots, and
// the files a module path names, are compared by real path now.

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d/b
// RUN: ln -s %S/Inputs/module_walkup/geometry %t.d/b/geolink
// RUN: cp %S/Inputs/symlink_main.k %t.d/b/main.k
// RUN: cd %t.d/b && %kairo main.k --type-check-only -I %S/Inputs/module_walkup/geometry
// RUN: cd %t.d/b && %kairo main.k --type-check-only
