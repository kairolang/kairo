// Adjacent string literals join whatever their prefixes. After a
// string, blanks and newlines are skipped and the next literal chains onto it
// (StringData::next) when it starts with `"` or with a string prefix glued to
// its quote: f, r, fr / rf, any case, the spellings lex_name accepts. Only the
// head is a token; the parser gives the node every segment's holes.
//
// Not a chain: a prefix with a space before its quote (`f "b"` is a name and
// a string), a word that is not a prefix (`ff`, `b`: there are no byte
// strings), and a char literal. A prefix glued to the closing quote
// (`"a"f"b"`) chains; it is not lexed as the literal's suffix, the whole
// `f"b"` swallowed. A plain suffix (`"a"s "b"`) is still a suffix, and the
// literal after it still chains.

fn chains(x: i32) {
    var a = "a" f"b{x}"
    var b = "a" r"\b"
    var c = f"a{x}" F"b{x}"
    var d = "a"f"b"
    var e = "a"
        rF"c{x}"
    var g = "a" """t""" Rf"u"
}

fn apart() {
    var p = "a" f "b"
    var q = "a" ff"b"
    var r = "a" b"x"
    var s = "a" 'c'
    var t = "a"s "b"
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only --print-tokens 2>/dev/null || true; } | %FileCheck %s --check-prefix=TOK
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
//
// Each chain is one token, the newline after it the next.
// TOK:      identifier 'a'
// TOK-NEXT: = '='
// TOK-NEXT: string '"a"'
// TOK-NEXT: `- string "a"   kind=none interp-exprs=0 next={{[0-9]+}}
// TOK-NEXT: new line
// TOK:      identifier 'b'
// TOK-NEXT: = '='
// TOK-NEXT: string '"a"'
// TOK-NEXT: `- string "a"   kind=none interp-exprs=0 next={{[0-9]+}}
// TOK-NEXT: new line
// TOK:      identifier 'c'
// TOK-NEXT: = '='
// TOK-NEXT: string '"a{x}"'
// TOK-NEXT: `- string "a{x}"   kind=f interp-exprs=1 next={{[0-9]+}}
// TOK:      new line
// TOK-NEXT: var 'var'
// TOK-NEXT: identifier 'd'
// TOK-NEXT: = '='
// TOK-NEXT: string '"a"' @ [{{[0-9]+}}, {{[0-9]+}})
// TOK-NEXT: `- string "a"   kind=none interp-exprs=0 next={{[0-9]+}}
// TOK-NEXT: new line
// TOK:      identifier 'e'
// TOK-NEXT: = '='
// TOK-NEXT: string '"a"'
// TOK-NEXT: `- string "a"   kind=none interp-exprs=0 next={{[0-9]+}}
// TOK-NEXT: new line
// TOK:      identifier 'g'
// TOK-NEXT: = '='
// TOK-NEXT: string '"a"'
// TOK-NEXT: `- string "a"   kind=none interp-exprs=0 next={{[0-9]+}}
// TOK-NEXT: new line
//
// Apart: two tokens each.
// TOK:      identifier 'p'
// TOK-NEXT: = '='
// TOK-NEXT: string '"a"'
// TOK-NEXT: `- string "a"   kind=none interp-exprs=0{{$}}
// TOK-NEXT: identifier 'f'
// TOK-NEXT: string '"b"'
// TOK:      identifier 'q'
// TOK-NEXT: = '='
// TOK-NEXT: string '"a"'
// TOK-NEXT: `- string "a"   kind=none interp-exprs=0{{$}}
// TOK-NEXT: identifier 'ff'
// TOK-NEXT: string '"b"'
// TOK:      identifier 'r'
// TOK-NEXT: = '='
// TOK-NEXT: string '"a"'
// TOK-NEXT: `- string "a"   kind=none interp-exprs=0{{$}}
// TOK-NEXT: identifier 'b'
// TOK-NEXT: string '"x"'
// TOK:      identifier 's'
// TOK-NEXT: = '='
// TOK-NEXT: string '"a"'
// TOK-NEXT: `- string "a"   kind=none interp-exprs=0{{$}}
// TOK-NEXT: character ''c''
// TOK:      identifier 't'
// TOK-NEXT: = '='
// TOK-NEXT: string '"a"'
// TOK-NEXT: `- string "a"   kind=none interp-exprs=0 next={{[0-9]+}}
// TOK-NEXT: new line
//
// The holes of later segments are the node's parts, in order.
// AST:      VariableDecl var a
// AST-NEXT: `-StringLiteralExpr "a"
// AST-NEXT: `-NamedIdentExpr x
// AST:      VariableDecl var c
// AST-NEXT: `-StringLiteralExpr "a{x}"
// AST-NEXT: |-NamedIdentExpr x
// AST-NEXT: `-NamedIdentExpr x
// AST:      VariableDecl var e
// AST-NEXT: `-StringLiteralExpr "a"
// AST-NEXT: `-NamedIdentExpr x
// AST:      VariableDecl var g
// AST-NEXT: `-StringLiteralExpr "a"
// AST-NEXT: `-FunctionDecl {{.*}}apart()
