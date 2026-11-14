// A builtin file given as the entry is part of the prelude, as it is when an
// ordinary program reaches it.
//
// - module.k, the builtin root itself, is the first file loaded and so has
//   file id 0. The builtin root is still recorded and its files are still
//   library code: the `<T: type>` generic in it is accepted (SC198E in a
//   user file).
// - extra.k, which the root re-exports: the prelude reaches the entry, so
//   the entry gets no edge back to the root, and every file of the graph
//   is preprocessed (I003E otherwise).
//
// --builtins-dir names the copy directly, so no other builtin root exists.

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t && mkdir -p %t && cp -r %S/Inputs/library_source_copy/. %t/
// RUN: cd %t && %kairo_bin --error-format=basic --resource-dir=%t/rd --builtins-dir=%t/src/builtin src/builtin/module.k --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error
// RUN: cd %t && %kairo_bin --error-format=basic --resource-dir=%t/rd --builtins-dir=%t/src/builtin src/builtin/extra.k --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error
