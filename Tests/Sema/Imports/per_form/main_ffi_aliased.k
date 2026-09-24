// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  use_ffi_aliased() -> i32
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// CASE 10b: `ffi ... import "h" as z` binds `z` to the header's own module.
// Sema/Foreign indexes legacy.h into a Kairo TU whose ModuleDecl (named after
// the file) shares the header's table, and phase I folds one module handle
// per header of the include closure under `legacy`, so `legacy::legacy_add`
// is an ordinary module step into a table built from clang's declarations
// (IMPORTS.md §5).
//
// Asserted here: the import is silent, and the PP consumes it, so the tree
// is just the function. What the names bind to is asserted in Tests/Sema/FFI
// and Tests/Sema/Imports/imports_all_forms.

ffi "c" import "legacy.h" as legacy

fn use_ffi_aliased() -> i32 {
    return 0
}
