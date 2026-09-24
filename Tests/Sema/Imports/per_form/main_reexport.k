// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  use_reexport() -> i32
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-CallExpr (0 args)
// AST-NEXT:         `-ChainExpr 'foo_reexport::helper'
// AST-NEXT:           |-NamedIdentExpr foo_reexport
// AST-NEXT:           `-Step ::helper
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// CASE 7: re-export. main imports foo_reexport, which does
// `pub import bar::*`. That edge is PUBLIC, so bar's names are part of
// foo_reexport's surface and must be reachable through it.
//
// A re-exported name lives in foo_reexport's OVERLAY, never in its symbol
// table, and a plain `import foo_reexport` binds its ModuleDecl -- whose
// shared table IS that symbol table. So the module step consults the source
// overlay after missing in the table (MemberLookup::reexport_lookup), and
// accepts a hit only when the origin import is pub/prot. IMPORTS.md §4.4.

import foo_reexport

fn use_reexport() -> i32 {
    return foo_reexport::helper()
}
