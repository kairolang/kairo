// An `extend` is outside code, not a class deriving from anything
// (extends.mdx), so extending a derived class does not hand its members
// the base's `prot` members. What `prot` does reach is every file of the
// module of the file that DECLARES the member (classes.mdx Visibility:
// "every file of the declaring file's module"), so the root that decides
// is the base's, not the extended class's.
//
// Inputs/access_ext_prot_module: lib/ and app/ are two modules (each has a
// module.k). lib/base.k's Base has the unmarked, so `prot`, field `ctx`, and
// the written `prot` field `tag` and method `bump`.
//   - lib/peek.k extends lib's Inner (derives Base) and uses all three: the
//     extend's file is in Base's module, so it may; it compiles and runs
//     (a `prot` member is `public:` in C++ in a module, so the extension's
//     companion struct reaches it).
//   - app/look.k extends app's Derived (derives Base) and reads Derived's
//     own `prot` field `own`: same module as Derived, allowed.
//   - app/bad.k extends Derived and uses the same three: app/ is not Base's
//     module and an extend is no subclass, so SC242E, with a note at the
//     `extend` that says why and names Base's module root.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/access_ext_prot_module && %kairo main_ok.k -o %t && %t
// RUN: cd %S/Inputs/access_ext_prot_module && { %kairo main_bad.k --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK:      bad.k:4:41: error [SC242E]: field 'ctx' of 'Base' is protected
// CHECK:      base.k:2:9: note [SC242N]: 'ctx' is protected by default
// CHECK-NEXT: bad.k:3:1: note [I900N]: an 'extend' of 'Derived' is not a class deriving from 'Base', so it does not get 'Base's 'prot' members through 'Derived': it can use 'ctx' only from a file of the module 'Base' is declared in, rooted at '{{.*}}access_ext_prot_module/lib' (the directory of its module.k)
// CHECK:      bad.k:4:52: error [SC242E]: field 'tag' of 'Base' is protected
// CHECK:      base.k:3:14: note [SC242N]: 'tag' is declared protected here
// CHECK-NEXT: bad.k:3:1: note [I900N]: an 'extend' of 'Derived' {{.*}} it can use 'tag' only from a file of the module 'Base' is declared in
// CHECK:      bad.k:4:63: error [SC242E]: method 'bump' of 'Base' is protected
// CHECK:      base.k:4:13: note [SC242N]: 'bump' is declared protected here
// CHECK-NEXT: bad.k:3:1: note [I900N]: an 'extend' of 'Derived' {{.*}} it can use 'bump' only from a file of the module 'Base' is declared in
