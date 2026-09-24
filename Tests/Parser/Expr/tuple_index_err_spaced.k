// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// An index must be glued to its separator. A gap is always a mistake, and
// allowing it makes macro-expanded synthetic locations unanswerable.
//
// The index is consumed on the way out, so this is ONE statement. Left in the
// stream it would come back as a second, phantom `0` statement.
// ERR: :11:2: error [S054E]: no whitespace allowed between the access operator and a tuple index
// AST: `-ExpressionStmt
// AST-NEXT:   `-NamedIdentExpr t
t. 0
