pub interface Named {
    fn tag(const self) -> i32
}
pub fn <T impl Named> get(a: T) -> i32 { return a.tag() }
