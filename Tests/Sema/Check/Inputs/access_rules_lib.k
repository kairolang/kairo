// Corpus for Sema/Check/access_rules.k: the module whose members are
// reached from another one.
pub class Vault {
    var secret: i32 = 7
    prot var shared: i32 = 11
    pub var open: i32 = 1
    static count: i32 = 3
    priv fn peek(const self) -> i32 { return self.secret }
    prot fn guard(const self) -> i32 { return self.shared }
    pub fn Vault(self) { }
    priv fn Vault(self, s: i32) { self.secret = s }
    prot fn Vault(self, a: i32, b: i32) { self.secret = a + b }
    priv class Key { pub var k: i32 = 2 }
    pub class Door { pub var d: i32 = 4 }
}

pub class <T> Cell {
    var item: T
    pub fn Cell(self, t: T) { self.item = t }
}

pub class Sealed derives priv Vault {
    pub fn Sealed(self) { }
}

pub class Guarded derives prot Vault {
    pub fn Guarded(self) { }
}
