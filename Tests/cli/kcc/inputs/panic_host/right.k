pub fn right(fail: bool) -> Panic<i32, i8, i64> {
    var wide: i64 = 2
    var narrow: i8 = 3
    if fail { return Panic<i32, i8, i64>::Err { error: wide } }
    return Panic<i32, i8, i64>::Err { error: narrow }
}
