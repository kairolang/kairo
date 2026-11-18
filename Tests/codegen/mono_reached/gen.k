pub struct <E> Wrap {
    pub var item: E
}
pub fn <V> leaf(a: V) -> i32 {
    return 5
}
pub fn <U> inner(a: U) -> i32 {
    return leaf(Wrap<U> { item: a }) + 2
}
pub fn <T> outer(a: T) -> i32 {
    return inner(Wrap<T> { item: a }) + 1
}
