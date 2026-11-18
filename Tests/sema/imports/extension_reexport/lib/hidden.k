import self::pt::Q
import self::tags::Marked
extend Q { pub fn hidden(self) -> i32 = self.v + 2 }
extend Q impl Marked { pub fn mark(const self) -> i32 = self.v + 4 }
