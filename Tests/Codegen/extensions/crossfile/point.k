// crossfile/point.k
pub struct Point { var x: i32; var y: i32; }

pub class Box {
    pub struct Inner { var v: i32; }
}

extend Point {
    pub fn sum(const self) -> i32 { return self.x + self.y; }
    // main never names Box, but this scope is defined whole wherever it is
    // touched: main's preamble must still be able to spell Box::Inner.
    priv fn peek(const self, i: Box::Inner) -> i32 { return self.x + i.v; }
}
