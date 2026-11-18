pub class <K> Table {
    pub struct Row {
        pub var key: K
        pub var n: i32
    }
    pub enum Mode { Fast, Slow }
    pub type Key = K

    pub var last: Self::Row
    pub fn Table(self, k: K) { self.last = Self::Row { key: k, n: 1 } }
    pub fn row(self, k: K, n: i32) -> Self::Row { return Self::Row { key: k, n: n } }
    pub fn put(self, r: Self::Row) { self.last = r }
}
