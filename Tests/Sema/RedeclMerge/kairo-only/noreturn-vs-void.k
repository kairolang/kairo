// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-FunctionDecl  n(i32) -> !
// AST-NEXT: | `-ParamDecl i32
// AST-NEXT: `-FunctionDecl  n(x: i32)
// AST-NEXT:   |-ParamDecl x: i32
// AST-NEXT:   `-CompoundStmt (0)
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [R039E]:
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: note [R039N]:
// END-GENERATED-CHECKS(AST)

// NO ORACLE: C++ has no ! return type. [[noreturn]] is an attribute, not
// part of the function type, so clang has no verdict to copy.
//
// UNDECIDED -- fill in the expectation once OVERLOAD.md rules on it:
//   (a) ! is a distinct return type   -> this is a return-type conflict
//   (b) ! is a modifier on void       -> these merge silently, which is
//                                        almost certainly wrong
// Note is_noreturn is a separate bool on FunctionDecl and return_type may
// be null for !, in which case _return_canonical maps BOTH to void and
// this file passes for the wrong reason. Check that before trusting it.
//
// EXPECT-UNDECIDED

fn n(i32) -> !
fn n(x: i32) { }
