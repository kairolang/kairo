// Corpus for Codegen/generics/member_spec_xmod.k: calls through the class
// without importing spec.k.
import lib::*

pub fn via_user() -> i32 {
    var a = G<i16>()
    var b = G<u8>()
    return a.m<i32>() * 100 + b.m<u16>() * 10 + b.m<i32>()
}
