pub interface Same {
    fn op ==(const self, other: Self) -> bool
    fn op -(const self) -> Self
}
pub fn <T impl Same> ne(a: T, b: T) -> i32 {
    if a != b { return 1 }
    return 0
}
pub fn <T impl Same> negeq(a: T, b: T) -> i32 {
    if -a == b { return 1 }
    return 0
}
