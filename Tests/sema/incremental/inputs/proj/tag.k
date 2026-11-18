import iface::*

pub struct Tag {
    pub var n: i32
}

extend Tag impl Named {
    pub fn name_len(const self) -> i32 = self.n
}
