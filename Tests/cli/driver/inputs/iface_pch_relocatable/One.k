// The first entry of Tests/cli/driver/incremental_iface_pch_relocatable.k:
// its graph holds Aaa.k, which sorts before Base.k and Callee.k.
import Aaa::aaa_len
import Base::base_n
import Callee::{
    Meta,
    take,
}

fn main() -> i32 {
    return take(Meta { s: "abc", a: 1, b: 2, c: 3 }) + (aaa_len("xy") as i32) + base_n()
}
