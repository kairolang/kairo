// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// XFAIL: *
//
// UNIMPLEMENTED: a BLOCK used as an expression on the right-hand side of a
// binding.
//
// Spec/Docs/control-flow.md:561 -- "Blocks are expressions when used as the
// right-hand side of a binding. The last expression in the block is [the
// value]." The parser instead commits to a SET LITERAL the moment it sees `{`
// in expression position, so `{ var t = 1; t * 2 }` is parsed as `{ <expr> }`
// and falls apart at the `var`.
//
// Today (remove this block along with the XFAIL when block-exprs land):
//   error [S054E]: expected '}' to close set literal
//   error [S052E]: expected expression, found 'var'
//   error [S052E]: expected expression, found '}'
//
// The contract asserted below is the minimum: it parses, with no errors, and
// the initializer is not mistaken for a set literal.
// Anchored on this file's TU: the prelude dumps the builtin TUs first, and
// they parse cleanly, so an unanchored error-count check matches THEIR footer
// and the AST-NOTs below stop covering this file at all.
// AST: TranslationUnit '{{.*}}block_expr_as_rhs.k'
// AST-NOT: SetLiteralExpr
// AST-NOT: RecoveryExpr
// AST-NOT: ============== AST (tree) for fid
// AST: -- 0 error(s), 0 warning(s) --

fn Test() { var x = { var t = 1; t * 2 }; }
