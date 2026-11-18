// Local declarations in an imported module: one in an ordinary body (only
// this TU sees it), one in an `inline` body and one in a generic body --
// both compiled again in the importer, which then needs the local declared.
pub fn compute(x: i32) -> i32 {
    fn helper(v: i32) -> i32 { return v * v }
    class Acc { pub var total: i32 = 0  fn add(self, v: i32) { self.total += v } }
    var a = Acc()
    a.add(helper(x))
    a.add(1)
    return a.total
}

pub inline fn quick(x: i32) -> i32 {
    fn helper(v: i32) -> i32 { return v + 1000 }
    return helper(x)
}

pub fn <T> tagged(x: T) -> i32 {
    enum Kind { Small, Big }
    fn kind_of(n: i32) -> Kind { if n > 10 { return Kind::Big } return Kind::Small }
    if kind_of(20) == Kind::Big { return 2 }
    return 0
}
