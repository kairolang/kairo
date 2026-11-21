// A COPY record that is not trivially copyable: the kind of parameter a
// read-only body could take by reference.

pub class Box {
    pub var n: i32 = 0
    pub fn Box(self, n: i32) { self.n = n }
    @copy pub fn Box(self, const o: Self) { self.n = o.n }
}
