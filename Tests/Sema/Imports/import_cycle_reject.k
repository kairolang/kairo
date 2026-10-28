// An import cycle is a compile error (modules.mdx, Circular Dependencies):
// R001E (placeholder) at the import that closes it, with a note at each
// import on the cycle, and a nonzero exit. The dependency scan used to keep
// that edge, so no file on the cycle was ever walked: `--type-check-only`
// printed nothing and exited 0, and a build died in codegen (I006F) -- the
// ticket "[Driver] An import cycle drops both user files: nothing is
// compiled, exit 0". Each case lives in Inputs/import_cycle/<case>/.
//
// Shapes: two files where the second imports the ENTRY back (fid 0, which
// used to read as "unresolved" wherever an import fid was tested), three
// files, a file importing itself, and a cycle through a `pub import`.

// RUN: cd %S/Inputs/import_cycle/two && not %kairo a.k --type-check-only 2>&1 | %FileCheck %s --check-prefix=TWO --implicit-check-not="error ["
// TWO: b.k:2:1: error [R001E]: import cycle: a.k -> b.k -> a.k; a module cannot import itself, directly or through other modules
// TWO-NEXT: a.k:2:1: note [I900N]: 'a.k' imports 'b.k' here
// TWO-NEXT: b.k:2:1: note [I900N]: 'b.k' imports 'a.k' here

// RUN: cd %S/Inputs/import_cycle/three && not %kairo a.k --type-check-only 2>&1 | %FileCheck %s --check-prefix=THREE --implicit-check-not="error ["
// THREE: c.k:2:1: error [R001E]: import cycle: a.k -> b.k -> c.k -> a.k; a module cannot import itself, directly or through other modules
// THREE-NEXT: a.k:1:1: note [I900N]: 'a.k' imports 'b.k' here
// THREE-NEXT: b.k:1:1: note [I900N]: 'b.k' imports 'c.k' here
// THREE-NEXT: c.k:2:1: note [I900N]: 'c.k' imports 'a.k' here

// RUN: cd %S/Inputs/import_cycle/self && not %kairo s.k --type-check-only 2>&1 | %FileCheck %s --check-prefix=SELF --implicit-check-not="error ["
// SELF: s.k:2:1: error [R001E]: 's.k' imports itself; a module cannot import itself, directly or through other modules

// RUN: cd %S/Inputs/import_cycle/pub && not %kairo main.k --type-check-only 2>&1 | %FileCheck %s --check-prefix=PUB --implicit-check-not="error ["
// PUB: b.k:1:1: error [R001E]: import cycle: a.k -> b.k -> a.k; a module cannot import itself, directly or through other modules
// PUB-NEXT: a.k:2:5: note [I900N]: 'a.k' imports 'b.k' here
// PUB-NEXT: b.k:1:1: note [I900N]: 'b.k' imports 'a.k' here
