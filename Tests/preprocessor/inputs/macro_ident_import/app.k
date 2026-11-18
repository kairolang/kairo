import lib::*

fn a() -> i32 {
    var n = 3
    return twice!(n)
}
fn b() -> i32 { return callee!()(4) }
fn c() -> i32 {
    var n = 3
    return plus!(n)
}
// a literal ARGUMENT substituted into the foreign body
fn d() -> i32 { return twice!(5) }

fn main() -> i32 {
    return a() + b() + other_fn() + c() + d()
}
