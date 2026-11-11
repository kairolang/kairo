// Corpus for Parser/Serialize/macros.k: macros another file expands. Their
// bodies hold literals and names that live in THIS file's tables, so the
// expanding file's serialized tree has to carry them by value. The padding
// shifts this file's identifier and literal indices away from the
// importer's, so a payload restored into the wrong table reads the wrong
// thing.
pub fn pad_a(x: i32) -> i32 { return x + 100 }
pub fn pad_b(x: i32) -> i32 { return x + 200 }
pub fn helper_fn(x: i32) -> i32 { return x }

pub macro forty!() { 40 }
pub macro two!() { "ab" "cd" }
pub macro greet!() { f"v={helper_fn(forty!()) + 2}" }
pub macro second!(t) { t.1 }
pub macro wrap!(e) { helper_fn(e) }
pub macro bad!() { no_such_name_in_lib + 1 }
