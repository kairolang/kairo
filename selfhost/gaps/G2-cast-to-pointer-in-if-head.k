// GAP G2: `x as unsafe *T` directly before the `{` of an if head.
//   kairo --syntax-only --error-format=basic G2-cast-to-pointer-in-if-head.k
//   -> S056E "expected '{' after 'if' condition", S052E "expected expression, found 'as'"
// `var b = x as unsafe *u8` and `if (x as unsafe *u8) == m {` both parse;
// Spec/Docs pointers.mdx writes `handle as unsafe *i32` as an ordinary
// expression. Site: Compiler/Memory/MMapRegion.k:203
// (`if mapping == MAP_FAILED as unsafe *u8 {`, already in main's source).
fn f(m: unsafe *u8, x: unsafe *u8) -> bool {
    if m == x as unsafe *u8 {
        return true
    }
    return false
}
