pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub fn <T impl Scalable> twice(a: T) -> i32 {
    return a.scale(2)
}
