import g::*
import s::*

pub fn fa() -> i32 {
    var h = Holder<Sq>{v: Sq{s: 1}}
    return total(Sq{s: 2}) + h.bad()
}
