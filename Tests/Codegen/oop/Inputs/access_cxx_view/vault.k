// Corpus for Codegen/oop/access_cxx_view.k: a module whose class has
// private and protected members, reached from its own file's functions --
// a `pub` inline one and a `pub` generic one, which a C++ host and an
// importing Kairo file compile in their own TUs.
pub class Vault {
    var secret: i32 = 7
    prot var shared: i32 = 11
    pub fn Vault(self) { }
    priv fn Vault(self, s: i32) { self.secret = s }
    priv fn peek(const self) -> i32 { return self.secret }
    pub fn open(const self) -> i32 { return self.peek() + self.shared }
}

priv fn helper(v: *Vault) -> i32 { return v->secret }

pub inline fn inline_read(v: *Vault) -> i32 { return v->secret + helper(v) }
pub fn <T> gen_read(v: *Vault, t: T) -> i32 { return v->peek() + v->shared }
pub fn make(s: i32) -> Vault { return Vault(s) }
