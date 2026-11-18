pub interface Make {
    static fn make() -> Self
    fn val(const self) -> i32
}
pub interface Holder {
    type Inner impl Make
    fn inner(const self) -> Self::Inner
}
pub interface Store {
    type Item impl Holder
    type <K> Map
    fn get(const self) -> Self::Item
    fn <K> wrap(const self, k: K) -> Self::Map<K>
    fn <K> unwrap(const self, m: Self::Map<K>) -> K
}
pub fn <T impl Store> deep(s: T) -> i32 {
    var x: T::Item::Inner = T::Item::Inner::make()
    return x.val() + s.get().inner().val()
}
pub fn <T impl Store> round(s: T, v: i32) -> i32 {
    var m: T::Map<i32> = s.wrap(v)
    return s.unwrap(m)
}
