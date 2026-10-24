// build: kairo F12-struct-literal-evaluates-in-declaration-order.k -o f23   (expect exit 21: b's initializer runs first)
struct P {
    var a: i32
    var b: i32
}

var LOG: i32 = 0

fn note(d: i32) -> i32 {
    LOG = LOG * 10 + d
    return d
}

fn main() -> i32 {
    var p = P { b: note(2), a: note(1) }   // written order: b, then a
    return LOG                             // 21 in written order; 12 today
}
