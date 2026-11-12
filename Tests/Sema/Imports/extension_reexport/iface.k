pub interface Doubled { fn twice(const self) -> i32 }
pub fn <T impl Doubled> quad(a: T) -> i32 { return a.twice() * 2 }
pub interface Halved { fn halfv(const self) -> i32 }
pub fn <T impl Halved> halve(a: T) -> i32 { return a.halfv() }
