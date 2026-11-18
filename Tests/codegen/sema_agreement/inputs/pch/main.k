// The entry of Tests/codegen/sema_agreement/interface_pch.k.
import util::*

fn main() -> i32 {
    return twice<i32>(1) + plain(0) // UNRELATED
}
