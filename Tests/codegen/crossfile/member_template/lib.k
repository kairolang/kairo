pub class Scale {
    pub var k: i32

    pub fn Scale(self, k: i32) { self.k = k }

    // A member TEMPLATE of a non-template class: its body lives in this file,
    // and is instantiated only in the TUs that call it.
    pub fn <T> first(const self, a: T, b: T) -> T { return a }
}
