// Compiler/Spec/Imports.md, One place per form: each import form looks in
// exactly one place.
//
//   import foo           the search roots (libraries, -I, the cwd, std, builtin)
//   import self::foo     the importing file's own directory
//   import module::foo   the importing file's module root: the nearest
//                        directory at or above it holding a module.k
//
// Every importing file below sits in a subdirectory of the cwd (lit runs in
// this directory), so a file beside it is never also reachable through the
// cwd root: what each run sees is that form's one place and nothing else.
//
// Inputs/import_anchors:
//   app/util.k            from_sibling(), helper()
//   app/sub/deep.k        deep_value()
//   libdir/util.k         from_lib()            (an -I dir below)
//   modroot/module.k      empty: modroot is a module root, not a library
//   modroot/shared.k, modroot/deep/peer.k
//   nomod/                no module.k at or above it

// --- lit wiring -----------------------------------------------------------

// `self::` reaches a sibling and a subdirectory, through every form that
// combines with it (selective, alias, wildcard), with no diagnostic.
// RUN: %kairo %S/Inputs/import_anchors/app/use_self.k --type-check-only > %t.self 2>&1
// RUN: %FileCheck %s --check-prefix=CLEAN --allow-empty --input-file=%t.self

// `module::` from two directories below the module root.
// RUN: %kairo %S/Inputs/import_anchors/modroot/deep/inner/user.k --type-check-only > %t.mod 2>&1
// RUN: %FileCheck %s --check-prefix=CLEAN --allow-empty --input-file=%t.mod

// A plain import reaches the library, never the same-named file beside the
// importer (which used to make it R017E, ambiguous).
// RUN: %kairo %S/Inputs/import_anchors/app/use_lib.k -I %S/Inputs/import_anchors/libdir --type-check-only > %t.lib 2>&1
// RUN: %FileCheck %s --check-prefix=CLEAN --allow-empty --input-file=%t.lib

// CLEAN-NOT: {{(error|warning) \[}}

// `module::` in a file with no module.k above it.
// RUN: { %kairo %S/Inputs/import_anchors/nomod/user.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=NOMOD --implicit-check-not="error [" --implicit-check-not="warning ["
// NOMOD: user.k:1:1: error [R069E]: cannot import 'module::shared': this file is in no module
// NOMOD-NEXT: user.k:1:1: note [R069N]: 'module::' starts at the module root: the nearest directory, at or above this file, that holds a module.k; there is none (an empty module.k is enough), or write 'self::' for a path beside this file

// A plain import that no search root answers but the importing file's
// directory does is an error with the `self::` fix-it. The import still
// resolves, so it is the only diagnostic.
// RUN: { %kairo %S/Inputs/import_anchors/app/use_legacy.k --type-check-only > %t.legacy 2>&1 || true; }
// RUN: %FileCheck %s --check-prefix=LEGACY --input-file=%t.legacy --implicit-check-not="error [" --implicit-check-not="warning ["
// LEGACY: use_legacy.k:1:8: error [R068E]: 'util' is not in any library or search directory; it is the file beside this one, which a plain import no longer reaches: write 'self::util'
// LEGACY-NEXT: fix-it:"{{.*}}use_legacy.k":{1:8-1:8}:"self::"

// The removed `import module foo`: an error with a fix-it deleting
// `module `, after which the line is read as plain `import util` (and so
// meets R068E too).
// RUN: { %kairo %S/Inputs/import_anchors/app/use_removed.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=REMOVED --implicit-check-not="error [" --implicit-check-not="warning ["
// REMOVED: use_removed.k:1:8: error [S089E]: 'import module foo' was removed; write 'import foo' (a library or -I path), 'import self::foo' (beside this file) or 'import module::foo' (from this module's root)
// REMOVED-NEXT: fix-it:"{{.*}}use_removed.k":{1:8-1:15}:""
// REMOVED: use_removed.k:1:15: error [R068E]:
// REMOVED-NEXT: fix-it:"{{.*}}use_removed.k":{1:15-1:15}:"self::"
