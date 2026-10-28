// Through b.k this time: fe is re-exported by a.k, which b.k re-exports.
import b::*

fn main() -> i32 { return fb() + fa() + fe() + fc() }   // 2 + 1 + 8 + 4
