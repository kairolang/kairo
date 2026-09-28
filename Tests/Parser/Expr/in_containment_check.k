// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
//
// The `in` CONTAINMENT operator. Spec/Docs/operators.md:302 lists
// `fn op in (self, other: T) -> bool` and spells this exact example
// ("containment check: if 5 in my_set", line 314); the precedence table gives
// it level 19, left-associative. In expression position `in` is a binary
// operator, not the `for x in xs` iteration keyword, so the `if` condition is
// the whole `5 in my_set` and nothing is left over for recovery.
//
// Anchored on this file's TU: the prelude dumps the builtin TUs first, and
// they parse cleanly, so an unanchored error-count check matches THEIR footer
// and the AST-NOTs below stop covering this file at all.
// AST: TranslationUnit '{{.*}}in_containment_check.k'
// AST: ConditionalStmt
// AST-NEXT: |-cond
// AST-NEXT: | `-BinaryOperatorExpr in
// AST-NEXT: |   |-IntegerLiteralExpr 5
// AST-NEXT: |   `-NamedIdentExpr my_set
// AST-NOT: RecoveryStmt
// AST-NOT: RecoveryExpr
// AST-NOT: ============== AST (tree) for fid
// AST: -- 0 error(s), 0 warning(s) --

fn Test() { if 5 in my_set { } }
