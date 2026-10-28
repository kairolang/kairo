// An extension in another file is not its target's class (extends.mdx:
// an `extend ... impl` placed in the interface's file cannot read the
// type's private members). Inputs/access_ext_other_file/show.k extends
// point.k's Point with `impl Show`, whose member reads the default-`priv`
// field `x` (line 4): refused, as from any other code of that file. The
// `impl Size` beside it reads only the `pub` field `y` (line 5): clean.
// point.k's own `extend Point` reads `x` freely.
//
// The C++ agrees: an extension's members are static members of a scope
// struct that only a SAME-file record befriends, so Kairo admitting this
// read left clang to refuse it.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/access_ext_other_file && { %kairo show.k --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// RUN: cd %S/Inputs/access_ext_other_file && { %kairo point.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=OWN --allow-empty
// CHECK: show.k:4:{{[0-9]+}}: error [SC001E]: field 'x' of 'Point' is private
// CHECK-NEXT: fix-it:"{{.*}}point.k":{2:5-2:5}:"pub "
// CHECK-NEXT: point.k:2:9: note [SC001N]: 'x' is private by default
// OWN-NOT: error
