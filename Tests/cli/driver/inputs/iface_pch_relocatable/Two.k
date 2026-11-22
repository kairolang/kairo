// The second entry of Tests/cli/driver/incremental_iface_pch_relocatable.k:
// its graph holds Base.k and Callee.k, and not Aaa.k.
import Base::base_n
import Callee::{
    Meta,
    take,
}

fn main() -> i32 {
    return take(Meta { s: "abcd", a: 1, b: 2, c: 3 }) + base_n()
}
