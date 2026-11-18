pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub interface Named {
    fn tag(const self) -> i32
}
pub fn <T impl Scalable> twice(a: T) -> i32 {
    return a.scale(2)
}
pub fn <T> both(a: T) -> i32 requires T impl Scalable && T impl Named {
    return a.scale(10) + a.tag()
}
