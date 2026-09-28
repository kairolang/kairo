// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
//
// Statement expression rules, each a hard syntax error: the last statement
// must be an expression (a declaration or a `return` has no value), the block
// may not be empty, and the `}` must be followed by `)`. Each bad form is
// reported once and the next line still parses.
// ERR: :19:16: error [S054E]: last statement of a statement expression must be an expression
// ERR-NEXT: :19:14: note [I900N]: the value of '({ ... })' is its last statement, which must be an expression
// ERR-NEXT: :20:14: error [S054E]: statement expression has no value
// ERR-NEXT: :20:14: note [I900N]: the value of '({ ... })' is its last statement, which must be an expression
// ERR-NEXT: :21:19: error [S054E]: expected ')' to close statement expression
// ERR-NEXT: :22:16: error [S054E]: last statement of a statement expression must be an expression
// ERR-NEXT: :22:14: note [I900N]: the value of '({ ... })' is its last statement, which must be an expression
// ERR-NEXT: :23:34: error [S054E]: last statement of a statement expression must be an expression
// ERR-NEXT: :23:14: note [I900N]: the value of '({ ... })' is its last statement, which must be an expression
// ERR-NOT: error

fn Bad() -> i32 {
    var x = ({ var t = 1 })
    var y = ({ })
    var z = ({ 1 }
    var w = ({ return 1 })
    var v = ({ var q = 1; q + 1; var r = q })
    return ({ 0 })
}
