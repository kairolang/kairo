// The first entry of Tests/cli/driver/incremental_iface_pch_static.k: its
// graph holds holder.k and plain.k.
import holder::Holder
import plain::fb

fn main() -> i32 {
    return Holder::n + fb(1)
}
