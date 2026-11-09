// Imported by app.k, not a test of its own.
pub class <T> Holder {
    pub var p: unsafe *T = &null
    pub var n: usize = 0
    fn Holder(self) {}
}
pub class Ni;
pub class Outer {
    pub struct Inner { pub var n: unsafe *Ni; pub var x: i32 }
    pub var k: i32 = 1
    fn Outer(self) {}
}
pub class Ni {
    pub var ga: Holder<Outer::Inner>
    pub var z: i32 = 2
    pub fn Ni(self) {}
}
