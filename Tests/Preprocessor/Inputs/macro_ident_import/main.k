import lib::*

fn a() -> i32 {
    var n = 3
    return twice!(n)
}
fn b() -> i32 { return callee!()(4) }

fn main() -> i32 {
    return a() + b() + other_fn()
}
