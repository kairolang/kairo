// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  use_ffi_bare() -> i32
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// CASE 10a: a bare ffi import folds every name the header -- and everything
// it includes -- declares into the overlay, unqualified, as the `#include`
// it stands for would. There is no miss gate any more: a typo in this file is
// an R020E like anywhere else (IMPORTS.md §5).
//
// Asserted here: the import is silent, and the PP consumes it, so the tree
// is just the function. The bindings are asserted in Tests/Sema/FFI.
//
// NOTE: no semicolon (stage1 optional). The PP's ffi scan terminates on a
// newline as well as on `;`, so this no longer over-consumes the next line.

ffi "c" import "legacy.h"

fn use_ffi_bare() -> i32 {
    return 0
}
