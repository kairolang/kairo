// Tests/cli/driver/incremental_iface_pch_static.k: a static field whose
// initializer is a call, so its definition is dynamically initialized.
fn seed() -> i32 {
    return 5
}

pub class Holder {
    pub static n: i32 = seed()
}
