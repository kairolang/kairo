import lib::*

class C {
    var v: i32
    fn C(self, v: i32) { self.v = v }
    counting!()
}

fn main() -> i32 {
    var a = C(5)
    var b = C(2)
    if a + b != 7 { return 1 }
    if a - b != 3 { return 2 }
    if a++ != 5 || a.v != 6 { return 3 }
    if ++a != 106 { return 4 }
    return 0
}
