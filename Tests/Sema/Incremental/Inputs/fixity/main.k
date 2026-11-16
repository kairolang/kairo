import lib::C
import mid::bump

pub fn use_it() -> i32 {
    return bump(C(), 1)
}
