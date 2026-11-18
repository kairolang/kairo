import outer::*

pub fn use_outer(o: Outer) -> i32 {
    var q = o.p
    return o.p.x
}
