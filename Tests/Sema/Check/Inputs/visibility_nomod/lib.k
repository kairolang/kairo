// Corpus for Sema/Check/visibility_file.k: a file with no module.k above
// it, so its `prot` and its unmarked declarations reach only this file.
pub fn open_fn() -> i32 { return 1 }
priv fn priv_fn() -> i32 { return 2 }
prot fn prot_fn() -> i32 { return 3 }
fn bare_fn() -> i32 { return 4 }

pub class Box {
    pub fn Box(self) { }
    pub var shown: i32 = 1
    var hidden: i32 = 2
    fn bare_m(const self) -> i32 { return 5 }
    priv fn priv_m(const self) -> i32 { return 6 }
    prot fn prot_m(const self) -> i32 { return 7 }
}

// Reads every one of them: its own file sees all.
pub fn lib_reads() -> i32 {
    var b = Box()
    return priv_fn() + prot_fn() + bare_fn() + b.hidden + b.bare_m() + b.priv_m() + b.prot_m()
}
