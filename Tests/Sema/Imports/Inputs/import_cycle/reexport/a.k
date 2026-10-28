// A mutual `pub import` pair: each re-exports the other.
pub import b::*
pub import e::*

pub fn fa() -> i32 { return 1 }
