// Two different copies of one library are still a duplicate root (R018E):
// the input's own library replaces only a root the driver would otherwise
// default, and only when every input agrees on which copy that is.
//
// - Inputs in two different copies of std: neither replaces the staged
//   copy, and the resolver reports both copies.
// - An explicit --std-dir naming another copy than the one the input is
//   in: the flag wins, and the input's copy collides with it.
//
// Same fixture as library_source_copy.k.

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t && mkdir -p %t && cp -r %S/Inputs/library_source_copy/. %t/
// RUN: cd %t && { %kairo_bin --error-format=basic --resource-dir=%t/rd src/std/user.k other/std/user.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TWO
// RUN: cd %t && not %kairo_bin --error-format=basic --resource-dir=%t/rd src/std/user.k other/std/user.k --type-check-only > /dev/null 2>&1
// TWO-DAG: error [R018E]: duplicate module root 'kairo::std': '{{.*}}/rd/std' and '{{.*}}/src/std' both claim it
// TWO-DAG: error [R018E]: duplicate module root 'kairo::std': '{{.*}}/rd/std' and '{{.*}}/other/std' both claim it
// RUN: cd %t && { %kairo_bin --error-format=basic --resource-dir=%t/rd --std-dir=%t/other/std src/std/user.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=FLAG
// RUN: cd %t && not %kairo_bin --error-format=basic --resource-dir=%t/rd --std-dir=%t/other/std src/std/user.k --type-check-only > /dev/null 2>&1
// FLAG: error [R018E]: duplicate module root 'kairo::std': '{{.*}}/other/std' and '{{.*}}/src/std' both claim it
