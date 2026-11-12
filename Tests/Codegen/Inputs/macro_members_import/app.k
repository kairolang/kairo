import lib::*

pub class Box {
    var v: i32
    fn Box(self, v: i32) { self.v = v }
    getter!()
    field!()
    adder!()
    clamp!()
    secret!()
    outer_got!()
    fn use_hidden(const self) -> i32 { return self.hidden() }
}

holder!()
cadd!()

fn main() -> i32 {
    var a = Box(7)
    var b = Box(5)
    if a.get() != 7 { return 1 }
    if a.extra != 30 { return 2 }
    if a + b != 12 { return 3 }
    if a.clamp(6) != 6 || b.clamp(6) != 5 { return 4 }
    if a.use_hidden() != 14 { return 6 }
    if a.got() != 8 { return 7 }
    var h = Holder()
    if h.twice() != 8 { return 5 }
    if kadd(40, 2) != 42 { return 8 }
    return 42
}
