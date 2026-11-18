// Homes the instances main.k uses: each is named here first, so this module
// holds its explicit instantiation and every other module sees `extern
// template`.
pub fn <T> twice(v: T) -> T { return v }

pub class <T> Box {
    pub var v: T
    pub fn get(self) -> T { return self.v }
}

pub fn home(b: *Box<u64>) -> u64 { return b->get() + twice<u64>(b->v) }
