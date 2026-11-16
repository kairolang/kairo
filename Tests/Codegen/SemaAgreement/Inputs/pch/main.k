// The entry of Tests/Codegen/SemaAgreement/interface_pch.k.
import util::*

fn main() -> i32 {
    return twice<i32>(1) + plain(0) // UNRELATED
}
