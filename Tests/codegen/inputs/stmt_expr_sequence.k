fn g() -> i32 { return 1; }
fn f(a: i32, b: i32) -> i32 { return a + b; }
fn h() -> i32 { return f(g(), g()); }
