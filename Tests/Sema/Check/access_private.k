// Access control is Kairo's (classes.mdx, Visibility): a `priv` member --
// a field or `static` by default, a method or constructor marked `priv` --
// is not accessible from another module, and Kairo reports it, so
// `--type-check-only` does. Inputs/access_other_module/main.k reads acc.k's
// private field (line 5) and private static (line 6), calls its `priv`
// method (line 7) and its `priv` constructor (line 8).
//
// Formerly an expected failure (ticket "[Sema] Access control is checked
// only by clang: private members and `priv` constructors", GitHub #93):
// --type-check-only accepted all four and only a full build reported them,
// as clang CL001E. AccessCheck reports each now (SC001E, a placeholder
// code), with a note at the member and a fix-it making it `pub`.
// access_rules.k has the full rule set; Codegen/oop/access_same_module.k
// the same-file side, which must compile and run.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/access_other_module && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: main.k:5:{{[0-9]+}}: error [SC001E]: field 'secret' of 'Acc' is private
// CHECK-NEXT: fix-it:"{{.*}}acc.k":{3:5-3:5}:"pub "
// CHECK-NEXT: acc.k:3:9: note [SC001N]: 'secret' is private by default
// CHECK: main.k:6:{{[0-9]+}}: error [SC001E]: static member 'hidden' of 'Acc' is private
// CHECK: main.k:7:{{[0-9]+}}: error [SC001E]: method 'peek' of 'Acc' is private
// CHECK-NEXT: fix-it:"{{.*}}acc.k":{5:5-5:9}:"pub"
// CHECK-NEXT: acc.k:5:13: note [SC001N]: 'peek' is declared private here
// CHECK: main.k:8:{{[0-9]+}}: error [SC001E]: this constructor of 'Acc' is private
