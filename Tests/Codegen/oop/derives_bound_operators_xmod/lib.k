// A base whose operators main.k uses through a `derives` bound, and a
// generic function over it declared here: its body is checked in this
// file against Meter's table and emitted into the importer's TU.

pub class Meter {
    pub var v: i32 = 0
    fn op + (self, o: i32) -> i32 { return self.v + o; }
    fn op == (self, o: i32) -> bool { return self.v == o; }
}

pub class Km derives Meter {
    fn Km(self, x: i32) { self.v = x * 1000; }
}

pub fn <T derives Meter> plus(a: T, k: i32) -> i32 { return a + k; }
