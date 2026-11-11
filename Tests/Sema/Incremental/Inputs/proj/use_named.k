import iface::*
import tag::*

pub fn <T impl Named> show(t: T) -> i32 {
    return t.name_len()
}

pub fn use_named() -> i32 {
    return show(Tag { n: 3 })
}
