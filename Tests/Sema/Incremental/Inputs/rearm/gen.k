import iface::*

pub class <T impl Named> Tagged {
    pub var v: T

    pub fn len(self) -> i32 {
        return self.v.name_len()
    }
}
