pub class Boxed {
    pub var v: i32 = 0;

    pub fn Boxed(self) { self.v = 1; }
    @copy pub fn Boxed(self, const other: Self) { self.v = other.v + 1; }
}
