pub class Dot {
    pub var x: i32 = 5
    pub fn area(const self) -> i32 { return self.x }
}

// Corpus for sema/check/impl_declared_other_file.k: the type, with one of
// Shape's members; dot_name.k adds the other.
