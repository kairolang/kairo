// GAP G7: a parameter list split over lines whose LAST parameter's type ends
// in a generic `>` and has no trailing comma.
//   kairo --syntax-only --error-format=basic G7-multiline-params-generic-last.k
//   -> S047E "expected ')' to close the parameter list" at the `(`
// `seen: vec<u8>,\n)` (trailing comma) and `seen: unsafe *u8\n)` both parse,
// so the newline after `>` is the trigger. Sites: Resolution/ImportProbe.k:1743,
// AST/Printer/ASTPrinter.k:4227, Preprocessor/Preprocessor.k:1148,
// Parser/DeclParse.k:885 (4 files whose first error this is).
fn c(
    seen: vec<u8>
) {
}
