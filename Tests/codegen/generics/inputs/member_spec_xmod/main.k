// Corpus for codegen/generics/member_spec_xmod.k: the program.
import lib::*
import spec::*
import user::*

fn main() -> i32 {
    var a = G<i16>()
    if a.m<u16>() != 1 { return 1 }
    if via_user() != 234 { return 2 }
    return 0
}
