priv fn scale(x: i32) -> i32 {
    return x * 100;
}

priv inline fn secret(x: i32) -> i32 {
    return scale(x);
}

fn helper(x: i32) -> i32 {
    return x + 1;
}

priv fn hidden() -> i32 {
    return 9;
}

pub inline fn twice_secret(x: i32) -> i32 {
    return secret(x) * 2;
}

pub fn open(x: i32) -> i32 {
    return helper(x) + hidden();
}
