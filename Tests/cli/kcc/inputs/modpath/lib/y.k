pub fn f() -> i32 { return 40 }

priv fn hidden() -> i32 { return 1 }

pub fn g() -> i32 { return hidden() + 1 }
