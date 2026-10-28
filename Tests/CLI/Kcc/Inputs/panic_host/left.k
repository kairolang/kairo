pub fn left(fail: bool) -> Panic<i32, i64> {
    var e: i64 = 40
    if fail { return Panic<i32, i64>::Err { error: e } }
    return Panic<i32, i64>::Ok { value: 1 }
}
