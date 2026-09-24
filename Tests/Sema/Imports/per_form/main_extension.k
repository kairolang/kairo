// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  use_extension() -> i32
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-BinaryOperatorExpr +
// AST-NEXT:         |-CallExpr (0 args)
// AST-NEXT:         | `-ChainExpr 'shape::area_a'
// AST-NEXT:         |   |-NamedIdentExpr shape
// AST-NEXT:         |   `-Step ::area_a
// AST-NEXT:         `-CallExpr (0 args)
// AST-NEXT:           `-ChainExpr 'shape::area_b'
// AST-NEXT:             |-NamedIdentExpr shape
// AST-NEXT:             `-Step ::area_b
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// CASE 9 (XFAIL): module extension across TUs. ext_a and ext_b each declare a
// module `shape`. Importing the SAME module name from two TUs should fold to
// ONE overlay key `shape` with TWO module targets (extension  scopes merge),
// NOT an ambiguity.
//
// XFAIL, two reasons:
//   (1) Test reach: `import ext_a::shape` binds `shape` from ext_a's file
//       scope; whether that surfaces as an unqualified `shape` key depends on
//       how the inner module is exposed by the file module.
//   (2) Real gap: OverlayEntry::is_ambiguous() counts non-function targets, and
//       a ModuleHandle IS non-function  so two same-named module targets would
//       currently trip R016 (ambiguity) instead of merging as an extension.
//       Fixing this needs is_ambiguous to exempt same-name ModuleHandle targets
//       (module extension) from the non-function ambiguity rule. See
//       RESOLUTION.md #2 (overlay multi-target: "module extension across TUs").

import ext_a::shape
import ext_b::shape

fn use_extension() -> i32 {
    return shape::area_a() + shape::area_b()
}
