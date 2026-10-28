import lib

struct Mine { var n: i32 }

class Reader impl lib::Src<Mine> {
    pub var v: i32
    fn read(self) panic(Mine) -> i32 {
        if self.v < 0 { panic Mine { n: self.v } }
        return self.v
    }
}

fn main() -> i32 {
    if (try lib::pick(Mine { n: 1 }, true) catch e: Mine => e.n catch e: lib::Oops => 50) != 1 { return 1 }
    if (try lib::pick(Mine { n: 1 }, false) catch e: Mine => e.n catch e: lib::Oops => 50 + e.n) != 57 { return 2 }
    if (try lib::pick(lib::Oops { n: 3 }, true) catch e: lib::Oops => e.n) != 3 { return 3 }
    var r = Reader { v: 4 }
    if (try lib::through<Mine, Reader>(r) catch e: Mine => e.n) != 5 { return 4 }
    var q = Reader { v: -2 }
    if (try lib::through<Mine, Reader>(q) catch e: Mine => e.n) != -2 { return 5 }
    return 0
}
