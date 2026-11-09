// `prot` is the module's (decided 2026-11-08): Inputs/visibility_mod/geo/
// holds a module.k, so every file under it shares shapes.k's `prot`
// declarations, and an unmarked declaration there is `prot` too.
//
//   geo/use.k   another file of the module: every `prot`, written or
//               unmarked, top-level and member, reached -- clean, and it
//               compiles and runs (`prot` members are `public:` in the
//               emitted C++, which has no "module" access). It also calls
//               geo/ext.k's `extend Shape`, whose body reads Shape's
//               `prot` members from another file of the module.
//   geo/peek.k  `priv` stays its file's own inside the module.
//   far.k       outside geo/: no `prot` of geo's, written or unmarked;
//               no SC272W, since the declaring file is in a module.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------

// RUN: cd %S/Inputs/visibility_mod/geo && %kairo use.k --type-check-only 2>&1 | %FileCheck %s --check-prefix=USE --allow-empty --implicit-check-not="error [" --implicit-check-not="warning ["
// USE-NOT: SC242
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/Inputs/visibility_mod/geo && %kairo use.k -o %t.d/use --cache-dir %t.d/c && %t.d/use; test $? -eq 41

// RUN: cd %S/Inputs/visibility_mod/geo && { %kairo peek.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=PEEK --implicit-check-not="error [" --implicit-check-not="warning ["
// PEEK: peek.k:7:18: error [SC242E]: 'secret' is private to its file
// PEEK-NEXT: fix-it:"{{.*}}/shapes.k":{4:1-4:5}:"pub"
// PEEK-NEXT: shapes.k:4:9: note [SC242N]: 'secret' is declared private here
// PEEK: peek.k:7:32: error [SC242E]: method 'inner' of 'Shape' is private
// PEEK-NEXT: fix-it:"{{.*}}/shapes.k":{11:5-11:9}:"pub"
// PEEK-NEXT: shapes.k:11:13: note [SC242N]: 'inner' is declared private here: accessible only in the file that declares 'Shape'

// RUN: cd %S/Inputs/visibility_mod && { %kairo far.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=FAR --implicit-check-not="error [" --implicit-check-not="warning ["
// FAR: far.k:7:18: error [SC242E]: 'scale' is protected to its module
// FAR-NEXT: fix-it:"{{.*}}/shapes.k":{2:1-2:5}:"pub"
// FAR-NEXT: shapes.k:2:9: note [SC242N]: 'scale' is declared protected here
// FAR: far.k:7:36: error [SC242E]: 'unit' is protected to its module
// FAR-NEXT: fix-it:"{{.*}}/shapes.k":{3:1-3:1}:"pub "
// FAR-NEXT: shapes.k:3:4: note [SC242N]: 'unit' is protected by default: a declaration with no visibility keyword is 'prot', visible in the files of its module (the directory of the nearest module.k)
// FAR: far.k:7:48: error [SC242E]: method 'area' of 'Shape' is protected
// FAR-NEXT: fix-it:"{{.*}}/shapes.k":{10:5-10:9}:"pub"
// FAR-NEXT: shapes.k:10:13: note [SC242N]: 'area' is declared protected here: accessible only in the module of the file that declares 'Shape' and in classes that derive from it
// FAR: far.k:7:59: error [SC242E]: field 'sides' of 'Shape' is protected
// FAR: far.k:7:69: error [SC242E]: field 'tag' of 'Shape' is protected
// FAR-NEXT: fix-it:"{{.*}}/shapes.k":{9:5-9:5}:"pub "
// FAR-NEXT: shapes.k:9:9: note [SC242N]: 'tag' is protected by default (a member with no visibility keyword is 'prot' in a module): accessible only in the module of the file that declares 'Shape' and in classes that derive from it
