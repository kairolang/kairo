// The file with the errors; identical in alone/ and cycle/. Only peer.k
// differs: in cycle/ it imports this file back.
import peer::*

pub class Meter {
    pub var reading: i32 = 0

    pub fn bump(self, by: i32) -> i32 {
        return self.reading + by + undeclared_step
    }
}

pub fn scaled(m: Meter, k: Gauge) -> i32 {
    return m.reading * k
}

pub fn reading_of(m: Meter) -> i32 {
    return m.reading
}

fn main() -> i32 {
    return base_offset()
}
