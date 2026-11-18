import shapes::*
pub interface Doubled { fn twice(const self) -> i32 }
extend Point impl Doubled { pub fn twice(const self) -> i32 = self.x * 2 }
extend Point { pub fn op + (self, o: Point) -> Point = Point { x: self.x + o.x } }
pub fn <T impl Doubled> quad(a: T) -> i32 { return a.twice() * 2 }
