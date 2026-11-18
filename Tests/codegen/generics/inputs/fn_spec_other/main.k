// Corpus for codegen/generics/fn_spec_other_module.k: the program.
import lib::*
import spec::*
import user::*

fn main() -> i32 {
    if use_u8() != 8 || use_u16() != 1 || pick<u8>() != 8 || pick<i32>() != 1 { return 1 }
    var t = Tag()
    t.n = 21
    if twice(t) != 42 || twice(3) != 2 { return 2 }
    return 0
}
