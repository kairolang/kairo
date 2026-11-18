// The class of out_of_line_member_visibility.k: every member is declared in
// the class and defined below it with no visibility keyword.

pub class Meter {
    pub var v: i32 = 0
    pub fn Meter(self, v: i32)
    pub fn step(self) -> i32
    pub fn peek(const self) -> i32
    pub static fn make() -> Meter
    pub fn op +(self, other: Meter) -> Meter
    pub fn <U> scaled(self, by: U) -> i32
    priv fn hidden(self) -> i32
    fn unmarked(self) -> i32
    prot fn guarded(self) -> i32
}

fn Meter::Meter(self, v: i32) {
    self.v = v
}

fn Meter::step(self) -> i32 {
    return self.v + 1
}

fn Meter::peek(const self) -> i32 {
    return self.v
}

static fn Meter::make() -> Meter {
    return Meter(1)
}

fn Meter::op +(self, other: Meter) -> Meter {
    return Meter(self.v + other.v)
}

fn <U> Meter::scaled(self, by: U) -> i32 {
    return self.v
}

fn Meter::hidden(self) -> i32 {
    return 1
}

fn Meter::unmarked(self) -> i32 {
    return 2
}

fn Meter::guarded(self) -> i32 {
    return 3
}

// Its own file reaches every member.
pub fn lib_reads() -> i32 {
    var m = Meter(1)
    return m.hidden() + m.unmarked() + m.guarded()
}
