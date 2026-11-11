import g::*
import s::*

pub fn fb() -> i32 {
    var h = Holder<Sq>{v: Sq{s: 1}}
    return total(Sq{s: 3}) + h.bad()
}
