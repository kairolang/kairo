// The second entry of Tests/cli/driver/incremental_iface_pch_static.k: its
// graph holds plain.k and not holder.k.
import plain::fb

fn main() -> i32 {
    return fb(4)
}
