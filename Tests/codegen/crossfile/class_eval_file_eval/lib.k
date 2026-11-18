// A file-level eval and a class eval field initialized from it, imported
// by app.k.

pub eval HDR: usize = 2 * sizeof usize

pub class S {
    pub var n: usize = 0
    pub eval H: usize = HDR + 1
    pub fn S(self) { self.n = S::H }
}
