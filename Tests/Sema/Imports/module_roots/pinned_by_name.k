// RUN: { %kairo %s --type-check-only -I %S/libfoo 2>&1 || true; } | %FileCheck %s
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// IMPORTS.md §2.1: a pinned library is reached by its declared name only.
// libfoo/module.k pins `foo`, so `foo::only` resolves and the bare `only` --
// the file's path under libfoo/, as if libfoo were an unnamed search dir --
// does not. That held for libfoo found as a subdirectory of the cwd (the
// second RUN) but not for libfoo named by -I (the first): the pin named the
// -I root without marking it a library, so the last-resort probe of every
// root found `only.k` by its bare path and the file had two spellings.

import foo::only as named
import only

// CHECK-NOT: error {{.*}}foo::only
// CHECK: pinned_by_name.k:13:1: error [R011E]: failed to resolve import path 'only'
// CHECK-NOT: error
