// A class whose marked operators are declared in the class and defined out
// of line in the same file. The definitions' bodies are read by an importer
// that names the operator through a generic (mid.k).

pub class C {
    pub var v: i32 = 0
    pub fn C(self) = default
    pub fn op r++(self) -> C
    pub fn op l++(self) -> C
}

fn C::op r++(self) -> C {
    self.v += 1
    return self
}

fn C::op l++(self) -> C {
    self.v = self.v + 1
    return self
}
