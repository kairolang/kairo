// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
x = try { risky() } catch e: Io::Error { -1 } catch { -2 }
// AST: TryCatchExpr (2 arms)
// AST-NEXT: CallExpr (0 args)
// AST-NEXT: NamedIdentExpr risky
// AST-NEXT: catch e Io::Error
// AST-NEXT: UnaryOperatorExpr prefix -
// AST-NEXT: IntegerLiteralExpr 1
// AST-NEXT: catch
// AST-NEXT: UnaryOperatorExpr prefix -
// AST-NEXT: IntegerLiteralExpr 2
