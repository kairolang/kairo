// Corpus for Sema/Check/access_static_through_edge.k: classes deriving a
// base `priv`, `prot` and plainly, whose static members, nested types and
// enumerators another module names through them.
pub class Base {
    pub static count: i32 = 7
    pub var x: i32 = 0
    pub static fn make() -> i32 { return 1 }
    pub fn twice(self) -> i32 { return 2 }
    pub fn Base(self) { }
    pub class Inner {
        pub var k: i32 = 1
    }
    pub enum Color { Red, Green }
}

pub class Der derives priv Base {
    pub fn Der(self) { }
    // The class that wrote the edge names its base's statics through itself.
    pub static fn own() -> i32 { return Der::make() + Der::count }
}

pub class Pro derives prot Base {
    pub fn Pro(self) { }
}

pub class Open derives Base {
    pub fn Open(self) { }
}

// One class further: the `priv` edge of Der is on the path.
pub class Far derives Der {
    pub fn Far(self) { }
}

pub type DerAlias = Der

// The file that wrote the edges names the members through anything.
pub fn lib_reads() -> i32 {
    var i = Der::Inner{}
    var c = Pro::Color::Red
    return Der::make() + Der::count + Pro::make() + Far::make() + DerAlias::make() + i.k
}
