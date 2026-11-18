// `=>` is one token. `<=>` still wins its longer munch, `>=` is unchanged, and
// a `>=` / `>>=` directly followed by `>` gives its `=` to a `=>`, so a
// generic close in front of a value arm lexes as `>` `=>` (`>>` `=>`, which the
// type parser then splits).

class <T> Box { }
class <K, V> Map { }
class <T> Vec { }

fn tokens(a: i32, b: i32, s: Box<i32>, m: Map<i32, Vec<i32>>) {
    var t1 = match a { default => b }
    var t2 = a <=> b
    var t3 = a >= b
    var k1 = match s { case Box<i32>=> 1 default => 0 }
    var k2 = match m { case Map<i32, Vec<i32>>=> 0 default => 1 }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %s --syntax-only --print-tokens 2>/dev/null || true; } | %FileCheck %s --check-prefix=TOK
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// TOK:      identifier 't1'
// TOK:      default 'default'
// TOK-NEXT: => '=>'
// TOK-NEXT: identifier 'b'
// TOK:      identifier 't2'
// TOK-NEXT: = '='
// TOK-NEXT: identifier 'a'
// TOK-NEXT: <=> '<=>'
// TOK-NEXT: identifier 'b'
// TOK:      identifier 't3'
// TOK-NEXT: = '='
// TOK-NEXT: identifier 'a'
// TOK-NEXT: >= '>='
// TOK-NEXT: identifier 'b'
// TOK:      identifier 'k1'
// TOK:      identifier 'Box'
// TOK-NEXT: < '<'
// TOK-NEXT: i32 'i32'
// TOK-NEXT: > '>'
// TOK-NEXT: => '=>'
// TOK-NEXT: integer '1'
// TOK:      identifier 'k2'
// TOK:      identifier 'Vec'
// TOK-NEXT: < '<'
// TOK-NEXT: i32 'i32'
// TOK-NEXT: >> '>>'
// TOK-NEXT: => '=>'
// TOK-NEXT: integer '0'
// AST:      VariableDecl var k1
// AST-NEXT:   `-MatchExpr (2 cases)
// AST-NEXT:     |-NamedIdentExpr s
// AST-NEXT:     |-case Box<i32>
// AST-NEXT:     | `-IntegerLiteralExpr 1
// AST:      VariableDecl var k2
// AST-NEXT:   `-MatchExpr (2 cases)
// AST-NEXT:     |-NamedIdentExpr m
// AST-NEXT:     |-case Map<i32, Vec<i32>>
// AST-NEXT:     | `-IntegerLiteralExpr 0
