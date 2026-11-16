// Corpus for Sema/Check/param_base_access.k: mixins that derive their type
// parameter `priv` and `prot`, used from another module.
pub class Base {
    pub var x: i32 = 1
    pub fn Base(self) { }
    pub fn f(self) -> i32 { return 10 }
    pub static fn make() -> i32 { return 5 }
}

pub class More derives Base {
    pub fn More(self) { }
    pub fn extra(self) -> i32 { return 20 }
}

pub class <A derives Base> Shut derives priv A {
    pub fn inside(self) -> i32 { return self.x + self.f() }
}

pub class <A derives Base> Half derives prot A {
    pub fn inside(self) -> i32 { return self.x }
}

pub class <A derives Base> Open derives A {
    pub fn inside(self) -> i32 { return self.x }
}

// The file that wrote the edges reaches the base through them.
pub fn lib_reads(s: *Shut<More>) -> i32 { return s->x + s->f() + s->extra() }
