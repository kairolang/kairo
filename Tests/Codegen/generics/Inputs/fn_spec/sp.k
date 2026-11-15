// Corpus for Codegen/generics/fn_spec_xfile.k: a generic function and its
// specialization, both public.
pub fn <T> pick() -> i32 { return 1 }
pub fn <> pick<i32>() -> i32 { return 2 }
