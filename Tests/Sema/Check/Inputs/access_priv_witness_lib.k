// Corpus for Sema/Check/access_priv_witness.k: conformers whose
// implementing member is not `pub`.
pub interface Area { fn area(const self) -> i32 }

// Declares `impl Area` beside its `priv` member: the member serves.
pub class Sq impl Area {
    pub fn Sq(self) { }
    priv fn area(const self) -> i32 { return 4 }
}

// Declares it through an `extend` in its own file: the `prot` member serves.
pub class Tri {
    pub fn Tri(self) { }
    prot fn area(const self) -> i32 { return 3 }
}
extend Tri impl Area { }

// Declares nothing: its `priv` member cannot serve a structural use.
pub class Rect {
    pub fn Rect(self) { }
    priv fn area(const self) -> i32 { return 6 }
}
