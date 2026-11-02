// Corpus for Preprocessor/macro_payload_import.k: macros whose bodies hold
// literals the importing file must read from THIS file's tables. The
// padding functions shift this file's identifier and literal indices away
// from the importer's, so a lookup in the wrong table finds the wrong thing.
pub fn pad_a(x: i32) -> i32 { return x + 100 }
pub fn pad_b(x: i32) -> i32 { return x + 200 }
pub fn helper_fn(x: i32) -> i32 { return x }

// A tuple index written in the body.
pub macro second!(t) { t.1 }
// A string in two parts: the second is chained off the first in this
// file's literal list.
pub macro two!() { "ab" "cd" }
// An f-string whose hole names a function of this file and a literal.
pub macro greet!() { f"v={helper_fn(40) + 2}" }
// An inline block's language string, from this file's literal list (type
// checked only: EmitIR does not emit inline blocks yet).
pub macro mark!() { inline "c++" { } }
