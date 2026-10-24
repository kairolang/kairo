import shape
pub fn <T impl shape::Scalable> outer(a: T) -> i32 {
    return shape::inner(shape::Wrap<T> { item: a }) + a.scale(1)
}
