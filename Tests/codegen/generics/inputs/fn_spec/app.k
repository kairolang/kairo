// Corpus for codegen/generics/fn_spec_xfile.k: an importer calling the
// primary at the specialized arguments and at others.
import sp::*

fn main() -> i32 {
    return pick<i32>() * 10 + pick<u8>() - 21
}
