// The preprocessor walk loaded a file the dependency scan had not:
// `import Dg::Dg::*` beside Dg.k (the R068E sibling case) resolves in the
// walk to its one-segment prefix, while the scan tried only the full path,
// so FileImportIndex::_resolve_greedy registered Dg.k with the lex workers
// reading the file table unlocked (VirtualFileManager's invariant). The scan
// now tries every prefix, longest first, as the walk does. A debug build
// logs the registration ("... during a preprocessor walk"); a release build
// never formats it, so there this test only checks the diagnostic.

// RUN: { %kairo -v --syntax-only %S/../Codegen/crossfile/ns_type_clash/Dg/E.k 2>&1 || true; } | %FileCheck %s --implicit-check-not="during a preprocessor walk"
// CHECK: E.k:2:8: error [R068E]: 'Dg' is not in any library or search directory; it is the file beside this one, which a plain import no longer reaches: write 'self::Dg::Dg'
