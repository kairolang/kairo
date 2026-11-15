// A file inside a source copy of one library also brings the directory
// beside that copy that pins the other library (src/builtin beside src/std),
// so a checkout is used as a whole. The toolchain's staged copy of the other
// library is not registered next to it. The fixture's rd/ is the staged tree.
//
// - src/std/sibling_user.k calls source_extra, which only the source
//   builtin declares, from the repo root, from inside src/std, and from
//   src/ (the cwd's own pinned-subdirectory scan finds src/builtin there).
// - src/builtin/sibling_user.k imports std::io and calls source_io, which
//   only the source std declares.
// - --builtins-dir wins for builtin: the staged builtin is used and
//   source_extra is gone.
// - other/std/none_user.k has no sibling and sees the staged builtin.

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t && mkdir -p %t && cp -r %S/Inputs/library_source_copy/. %t/
// RUN: cd %t && %kairo_bin --error-format=basic --resource-dir=%t/rd src/std/sibling_user.k --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error
// RUN: cd %t/src/std && %kairo_bin --error-format=basic --resource-dir=%t/rd sibling_user.k --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error
// RUN: cd %t/src && %kairo_bin --error-format=basic --resource-dir=%t/rd std/sibling_user.k --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error
// RUN: cd %t && %kairo_bin --error-format=basic --resource-dir=%t/rd src/builtin/sibling_user.k --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error
// RUN: cd %t && %kairo_bin --error-format=basic --resource-dir=%t/rd src/std/flag_user.k --builtins-dir=%t/rd/builtin --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error
// RUN: cd %t && { %kairo_bin --error-format=basic --resource-dir=%t/rd src/std/sibling_user.k --builtins-dir=%t/rd/builtin --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=FLAG
// RUN: cd %t && %kairo_bin --error-format=basic --resource-dir=%t/rd other/std/none_user.k --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error

// FLAG: error
// FLAG-SAME: source_extra
