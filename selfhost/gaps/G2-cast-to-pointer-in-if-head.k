// GAP G2: `x as unsafe *T` directly before the `{` of an if head.
//   kairo --syntax-only --error-format=basic G2-cast-to-pointer-in-if-head.k
//   -> S056E "expected '{' after 'if' condition", S052E "expected expression, found 'as'"
// `var b = x as unsafe *u8` and `if (x as unsafe *u8) == m {` both parse;
// Spec/Docs pointers.mdx writes `handle as unsafe *i32` as an ordinary
// expression. Site: Compiler/Memory/MMapRegion.k:203
// (`if mapping == MAP_FAILED as unsafe *u8 {`, already in main's source).
// Not only pointers, and not only `if` (2026-11-03): ANY `x as T` that ends
// an if / match head fails the same way. `if c == 5 as u8 {` and
// `match kind as TokenKind {` (Compiler/Token/TokenKind.k:312 after the
// int -> closed enum casts became `as`; redundant_parens drops the head's
// parens) both give S056E + S052E "found 'as'"; `var b = c == 5 as u8`
// parses.
fn f(m: unsafe *u8, x: unsafe *u8) -> bool {
    if m == x as unsafe *u8 {
        return true
    }
    return false
}

fn g(c: u8, kind: u32) -> i32 {
    if c == 5 as u8 {
        return 1
    }
    match kind as u8 {
        case 0 { return 2 }
        default { return 3 }
    }
}
