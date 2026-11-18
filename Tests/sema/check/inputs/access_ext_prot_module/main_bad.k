import app::other::Derived
import app::bad::*
fn main() -> i32 { var d = Derived(); return d.base_v() }
