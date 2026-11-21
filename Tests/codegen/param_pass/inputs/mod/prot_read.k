// A file under a module.k: an unmarked function is `prot`, so another file
// of the module may declare and call it, and it keeps the written form.
// A `priv` one stays in this file.

static calls: i32 = 0

pub class Box {
    pub var n: i32 = 0
    pub fn Box(self, n: i32) { self.n = n }
    @copy pub fn Box(self, const o: Self) { self.n = o.n }
}

fn prot_read(b: Box) -> i32 { calls += 1; return b.n }

priv fn priv_in_module(b: Box) -> i32 { calls += 1; return b.n }
