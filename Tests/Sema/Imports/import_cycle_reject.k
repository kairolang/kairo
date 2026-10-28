// An import cycle is an ERROR under -fno-import-cycles (by default it is
// the warning R001W and compiles: import_cycle.k): R001E (placeholder) at the
// import that closes it, with a note at each import on the cycle, and a
// nonzero exit. The dependency scan used to keep that edge, so no file on the
// cycle was ever walked: `--type-check-only` printed nothing and exited 0, and
// a build died in codegen (I006F) -- the ticket "[Driver] An import cycle
// drops both user files: nothing is compiled, exit 0". Each case lives in
// Inputs/import_cycle/<case>/.
//
// Shapes: two files where the second imports the ENTRY back (fid 0, which
// used to read as "unresolved" wherever an import fid was tested), three
// files, a file importing itself (with a fix-it that removes the import),
// and a cycle through a `pub import`.

// RUN: cd %S/Inputs/import_cycle/two && not %kairo a.k -fno-import-cycles --type-check-only 2>&1 | %FileCheck %s --check-prefix=TWO --implicit-check-not="error ["
// TWO: b.k:2:1: error [R001E]: import cycle: a.k -> b.k -> a.k; import cycles are disabled (-fno-import-cycles)
// TWO-NEXT: a.k:2:1: note [I900N]: 'a.k' imports 'b.k' here
// TWO-NEXT: b.k:2:1: note [I900N]: 'b.k' imports 'a.k' here
// TWO-NEXT: note [I900N]: move the declarations the modules share into a third module that each of them imports

// RUN: cd %S/Inputs/import_cycle/three && not %kairo a.k -fno-import-cycles --type-check-only 2>&1 | %FileCheck %s --check-prefix=THREE --implicit-check-not="error ["
// THREE: c.k:2:1: error [R001E]: import cycle: a.k -> b.k -> c.k -> a.k; import cycles are disabled (-fno-import-cycles)
// THREE-NEXT: a.k:1:1: note [I900N]: 'a.k' imports 'b.k' here
// THREE-NEXT: b.k:1:1: note [I900N]: 'b.k' imports 'c.k' here
// THREE-NEXT: c.k:2:1: note [I900N]: 'c.k' imports 'a.k' here
// THREE-NEXT: note [I900N]: move the declarations the modules share into a third module that each of them imports

// RUN: cd %S/Inputs/import_cycle/self && not %kairo s.k -fno-import-cycles --type-check-only 2>&1 | %FileCheck %s --check-prefix=SELF --implicit-check-not="error ["
// SELF: s.k:2:1: error [R001E]: 's.k' imports itself; import cycles are disabled (-fno-import-cycles)
// SELF-NEXT: fix-it:"{{.*}}s.k":{2:1-2:{{[0-9]+}}}:""

// RUN: cd %S/Inputs/import_cycle/pub && not %kairo main.k -fno-import-cycles --type-check-only 2>&1 | %FileCheck %s --check-prefix=PUB --implicit-check-not="error ["
// PUB: b.k:1:1: error [R001E]: import cycle: a.k -> b.k -> a.k; import cycles are disabled (-fno-import-cycles)
// PUB-NEXT: a.k:2:5: note [I900N]: 'a.k' imports 'b.k' here
// PUB-NEXT: b.k:1:1: note [I900N]: 'b.k' imports 'a.k' here
// PUB-NEXT: note [I900N]: move the declarations the modules share into a third module that each of them imports
