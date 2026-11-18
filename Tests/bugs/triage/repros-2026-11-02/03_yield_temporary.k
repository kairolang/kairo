// yield of a non-lvalue expression.
// Expected: compiles; sum of squares 0..3 = 14.
// Actual: CL001E "non-const lvalue reference to type 'long' cannot bind to a
// temporary" -- YieldPromise::yield_value takes `@inout v: T`. Yielding a
// named variable works.
fn squares(n: i64) -> yield i64 {
    for var i: i64 = 0; i < n; i += 1 { yield i * i }
}

fn main() -> i32 {
    var s: i64 = 0
    for v in squares(4) { s += v }
    return s as i32   // exit 14
}
