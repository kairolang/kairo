// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// A rejected index must be CONSUMED on the way out. Left in the stream, the
// postfix loop breaks on the failed step and the statement loop then re-parses
// the same integer as a statement of its own -- two statements per source line,
// and a stray IntegerLiteralExpr that never appeared in the source.
// ERR: :20:3: error [S054E]: tuple index must be a plain decimal integer
// ERR: :21:3: error [S054E]: tuple index must be a plain decimal integer
// ERR: :22:3: error [S054E]: tuple index must be a plain decimal integer
// ERR: :23:3: error [S054E]: tuple index must be a plain decimal integer
// AST: |-ExpressionStmt
// AST-NEXT: | `-NamedIdentExpr t
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-NamedIdentExpr t
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-NamedIdentExpr t
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-NamedIdentExpr t
// AST-NOT: IntegerLiteralExpr
t.0x1
t.1u8
t.1_0
t.01
