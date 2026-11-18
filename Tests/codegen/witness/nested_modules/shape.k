pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub struct <E> Wrap {
    pub var item: E
}
extend <E> Wrap<E> {
    pub fn scale(const self, factor: i32) -> i32 = factor + 10
}
pub fn <U impl Scalable> inner(a: U) -> i32 {
    return a.scale(2)
}
