// Corpus for Codegen/generics/fn_spec_other_module.k: specializations of
// lib.k's functions, written in a module of their own.
import lib::*

pub class Tag { pub var n: i32 = 0 }

pub fn <> pick<u8>() -> i32 { return 8 }
pub fn <> twice<Tag>(x: Tag) -> i32 { return x.n * 2 }
