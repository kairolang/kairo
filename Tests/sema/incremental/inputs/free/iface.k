pub interface Named {
    fn name_len(const self) -> i32
}

pub fn <T impl Named> len_of(v: T) -> i32 {
    return v.name_len()
}
