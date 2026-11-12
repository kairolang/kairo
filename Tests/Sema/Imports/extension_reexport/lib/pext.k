import self::pt::Q
import self::tags::Tagged
extend Q { pub fn shown(self) -> i32 = self.v + 1 }
extend Q impl Tagged { pub fn tag(const self) -> i32 = self.v + 3 }
