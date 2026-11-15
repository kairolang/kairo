// The Kairo half of kcc_finally_layout.k: a local `finally()` ends on every
// path (unflagged storage) and one it ends on one path (flagged), so the
// host TU holds the union-storage helpers.
pub class Wide {
    pub var x: i64 = 1
    pub var y: i8  = 2
    pub fn Wide(self) = default
    fn op finally(self) { }
}

inline fn read(p: *Wide) -> i64 {
    return p->x + (p->y as i64)
}

pub inline fn probe(c: bool) -> i64 {
    var a = Wide()
    var b = Wide()
    var r = read(&a) + read(&b)
    a.finally()
    if c {
        b.finally()
    }

    return r
}
