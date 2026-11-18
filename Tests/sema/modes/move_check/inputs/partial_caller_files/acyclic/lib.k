// Imported by main.k: functions that leave a part of their argument
// moved-from.
pub class Str {
    pub var n: i32 = 0
    pub fn Str(self) { }
    @move pub fn Str(self, other: Self) { self.n = other.n; other.n = 0 }
}

pub class Holder {
    pub var a: Str
    pub var b: Str
    pub fn Holder(self) { }
    pub fn take_a(self) -> Str { return self.a }
}

pub fn drain(@inout h: Holder) -> Str { return h.b }
