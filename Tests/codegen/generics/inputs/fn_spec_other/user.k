// Corpus for codegen/generics/fn_spec_other_module.k: calls lib.k's
// primaries at the specialized arguments without importing spec.k.
import lib::*

pub fn use_u8() -> i32 { return pick<u8>() }
pub fn use_u16() -> i32 { return pick<u16>() }
