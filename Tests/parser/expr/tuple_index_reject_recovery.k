// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// A rejected index must be CONSUMED on the way out. Left in the stream, the
// postfix loop breaks on the failed step and the statement loop then re-parses
// the same integer as a statement of its own -- two statements per source line,
// and a stray IntegerLiteralExpr that never appeared in the source.
// These pin ABSOLUTE line numbers against the code at the bottom of the file:
// anything inserted above it shifts every one of them.
// ERR: :30:3: error [S054E]: tuple index must be a plain decimal integer
// ERR: :31:3: error [S054E]: tuple index must be a plain decimal integer
// ERR: :32:3: error [S054E]: tuple index must be a plain decimal integer
// ERR: :33:3: error [S054E]: tuple index must be a plain decimal integer
// The prelude puts the builtin TUs in the tree dump too, and they are full of
// integer literals -- anchor on THIS file's TU, or the AST-NOT below reads
// builtin's enum discriminants instead of this file's statements.
// AST: TranslationUnit '{{.*}}tuple_index_reject_recovery.k'
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-NamedIdentExpr t
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-NamedIdentExpr t
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-NamedIdentExpr t
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-NamedIdentExpr t
// AST-NOT: IntegerLiteralExpr
// Bounds the NOT above to THIS file's tree: without a trailing anchor the
// excluded region runs to EOF, over the builtin TUs the prelude appends --
// whose enum discriminants are integer literals.
// AST: -- 4 error(s), 0 warning(s) --
t.0x1
t.1u8
t.1_0
t.01
