// An identifier in this macro body is interned in THIS file's table; the
// importing file must look it up by spelling, not by this file's index.
pub fn helper_fn(x: i32) -> i32 { return x }
pub fn other_fn() -> i32 { return 7 }
pub macro twice!(x) { helper_fn(helper_fn(x)) }
pub macro callee!() { helper_fn }
