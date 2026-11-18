// A file inside a source copy of builtin or std (a checkout's Lib/std/io.k)
// is checked against that copy, not the toolchain's staged one. The two
// copies claim one root name, so registering the staged copy as well is
// R018E. The fixture's rd/ is the staged tree, reached through
// --resource-dir (whose builtin/ and std/ the driver uses when no
// --builtins-dir or --std-dir is given); src/ holds the source copies.
//
// - src/std/user.k imports std::io and calls source_io, which only the
//   source copy's io.k declares: std::io resolves inside the copy.
// - The same from the library's own directory as the cwd.
// - src/builtin/extra.k and src/builtin/module.k: the same for builtin.
//   The source module.k declares a `<T: type>` generic, legal only in
//   library code, so the copy is also checked as library code.
// - prog/main.k sits outside every library and still sees the staged std
//   (staged_io exists only there).
//
// The fixture is copied, not linked: a symlink would make both roots one
// directory, which is never a collision.

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t && mkdir -p %t && cp -r %S/inputs/library_source_copy/. %t/
// RUN: cd %t && %kairo_bin --error-format=basic --resource-dir=%t/rd src/std/user.k --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error
// RUN: cd %t && %kairo_bin --error-format=basic --resource-dir=%t/rd src/std/io.k --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error
// RUN: cd %t/src/std && %kairo_bin --error-format=basic --resource-dir=%t/rd user.k --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error
// RUN: cd %t && %kairo_bin --error-format=basic --resource-dir=%t/rd src/builtin/extra.k --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error
// RUN: cd %t && %kairo_bin --error-format=basic --resource-dir=%t/rd src/builtin/module.k --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error
// RUN: cd %t && %kairo_bin --error-format=basic --resource-dir=%t/rd prog/main.k --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error
