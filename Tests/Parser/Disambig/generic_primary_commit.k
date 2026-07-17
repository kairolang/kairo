// A primary generic in the DisambigTable commits `<` as generic args
// without a tentative parse.

fn <T> gen(v: T) -> T {
    return v
}

fn main() -> i32 {
    var g = gen<i32>(5)
    return 0
}
