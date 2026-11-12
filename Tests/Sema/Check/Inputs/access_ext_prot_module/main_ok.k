import lib::der::Inner
import lib::peek::*
import app::other::Derived
import app::look::*
fn main() -> i32 {
    var i = Inner()
    var d = Derived()
    return i.peek() + d.own_v() + d.in_body() - 21
}
