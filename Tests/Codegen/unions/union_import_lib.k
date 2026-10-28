pub union <T, U> Either {
    var left: T
    var right: U
}

pub union Bits {
    var i: i32
    var f: f32
}

pub fn make_bits(v: i32) -> Bits {
    var b: Bits
    b.i = v
    return b
}

pub fn left_of(e: Either<i32, f32>) -> i32 {
    return e.left
}
