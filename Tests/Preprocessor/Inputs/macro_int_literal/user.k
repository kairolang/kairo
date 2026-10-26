// Corpus for Preprocessor/macro_int_literal_import.k: an IMPORTED file that
// expands a macro defined in another file (defs.k) to an integer literal.
import defs

pub fn get() -> i32 {
    return defs::seven!()
}
