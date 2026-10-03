pub class Gate {
    pub var open: bool
    pub inline fn is_open(self) -> bool { return self.open }
}

pub inline fn twice(x: i32) -> i32 { return x * 2 }
