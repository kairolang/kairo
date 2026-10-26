union <T, U> Either {
    var left: T
    var right: U
}



fn main() -> i32 {
    var e: Either<i32, f32>
    e.left = 42
    return 0
}