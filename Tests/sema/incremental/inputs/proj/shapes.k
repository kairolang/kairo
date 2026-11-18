pub struct Point {
    pub var x: i32
    pub var y: i32
    // SLOT-field
}

pub class Counter {
    priv var n: i32 = 0

    priv fn step(self, by: i32) {
        self.n = self.n + by
    }

    pub fn get(self) -> i32 {
        self.step(1)
        return self.n
    }
}
