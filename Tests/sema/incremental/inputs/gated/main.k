import bridge::*
import lib::*
ffi "c++" import "plain.hh"

fn pass(s: string) -> i32 {
    return answer()
}

fn main() -> i32 {
    var s: string = "abc"
    return pass(s)
}
