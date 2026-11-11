// Corpus for Preprocessor/fstring_chain_macro_holes.k: macros of an imported
// file whose f-string holes sit in a later segment of a chain. The padding
// shifts this file's identifier and literal indices away from the
// importer's, so a hole or a segment read against the wrong table finds the
// wrong thing.
pub fn pad_a(x: i32) -> i32 { return x + 100 }
pub fn pad_b(x: i32) -> i32 { return x + 200 }
pub fn twice(x: i32) -> i32 { return x * 2 }

pub macro show!(x) { "s=" f"{x}" " t=" f"{twice(x)}" }
pub macro forty! { 40 }
pub macro shown! { r"\f=" f"{forty!}" "!" }
