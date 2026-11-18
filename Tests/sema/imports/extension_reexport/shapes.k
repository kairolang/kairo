import iface::*
pub struct Point { pub var x: i32 }
extend Point { pub fn half(self) -> i32 = self.x / 2 }
extend Point impl Halved { pub fn halfv(const self) -> i32 = self.x / 2 }
