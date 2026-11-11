import lib::*

eval N: i32 = LIMIT + 1

fn main() -> i32 {
    var p       = P { x: 1, y: 2 }
    var q       = ident(p.x)
    var b       = Box(3)
    var i: Id   = util::helper(b.get())
    var m: Mode = Mode::On
    return add(q, p.sum()) + i + N
}
