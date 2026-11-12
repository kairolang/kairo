import shapes::*
import iface::*
extend Point impl Doubled { pub fn twice(const self) -> i32 = self.x * 2 }
extend Point { pub fn triple(self) -> i32 = self.x * 3 }
