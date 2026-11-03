// GAP G1: inside brackets, an operand that ends in a CAST (`x as i32`) or a
// closing PAREN ends the expression at a newline, so a binary operator
// leading the next line is rejected (both calls below fail, 14:20 and 17:13).
//   kairo --syntax-only --error-format=basic G1-paren-operand-newline.k
//   -> S057E / S054E "expected ')' to close function call argument list",
//      "expected ',' or ')' after argument in function call"
// The same call with a bare operand (`g(x\n + 1, 2)`) parses, so the rule is
// not "newline ends the expression inside brackets"; these forms are the
// inconsistent ones. Already noted in Scripts/Migration/README
// (cpp_casts) and private/IMPORTANT/TICKETS.TXT.
// Self-host sites: EvalHash.k:131, Lexer.k:1937, PrimaryExpressions.k:974,
// CodegenContext.k:110, ExprParse.k:1392, TokenBuffer.k:182 (if head) ...
fn g(a: i32, b: i32) -> i32 { return a }

fn f(x: u8) -> i32 {
    var ok = g(x as i32
        + 1, 2)
    return g(
        (x as i32)
            + 1, 2)
}
