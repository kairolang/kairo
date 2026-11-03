// Corpus for Preprocessor/fstring_macro_holes.k: macros whose f-strings
// the importing file expands. The padding shifts this file's identifier
// and literal indices away from the importer's, so a hole read against the
// wrong table finds the wrong thing.
pub fn pad_a(x: i32) -> i32 { return x + 100 }
pub fn pad_b(x: i32) -> i32 { return x + 200 }
pub fn twice(x: i32) -> i32 { return x * 2 }

// A parameter in a hole, next to a call of this file's function.
pub macro show!(x) { f"s={x} t={twice(x)}" }
pub macro forty! { 40 }
// An invocation of this file's macro in a hole.
pub macro shown! { f"f={forty!}" }
