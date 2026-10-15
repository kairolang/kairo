fn main() -> i32 {
    var n: i32 = 0;
    var f = fn () |*| { n += 1; };
    return 0;
}

// ERRORS
