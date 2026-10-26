// Corpus for Preprocessor/macro_int_literal_import.k: the input file. It
// imports user.k, which is therefore an imported (non-input) file.
import user

fn main() -> i32 {
    return user::get()
}
