// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// XFAIL: *
//
// UNIMPLEMENTED: the `in` CONTAINMENT operator.
//
// Spec/Docs/operators.md:302 lists `fn op in (self, other: T) -> bool` and
// spells this exact example ("containment check: if 5 in my_set", line 314);
// the precedence table gives it level 19, left-associative. The parser only
// knows `in` as the `for x in xs` iteration keyword, so in expression position
// it bails: the `if` condition ends at `5`, and `in` is then an unexpected
// token.
//
// Today (remove this block along with the XFAIL when `in` lands):
//   error [S056E]: expected '{' after 'if' condition
//   error [S052E]: expected expression, found 'in'
// and the body parses as RecoveryStmt + a stray NamedInitializerExpr.
//
// The contract asserted below is the minimum: it parses, with no errors.
// Anchored on this file's TU: the prelude dumps the builtin TUs first, and
// they parse cleanly, so an unanchored error-count check matches THEIR footer
// and the AST-NOTs below stop covering this file at all.
// AST: TranslationUnit '{{.*}}in_containment_check.k'
// AST-NOT: RecoveryStmt
// AST-NOT: RecoveryExpr
// AST-NOT: ============== AST (tree) for fid
// AST: -- 0 error(s), 0 warning(s) --

fn Test() { if 5 in my_set { } }
