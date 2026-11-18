// The classes of access_member_type_through_edge.k.

pub class Base {
    pub class Inner { pub var k: i32 = 0 }
    priv class Hidden { pub var k: i32 = 0 }
    pub type Num = i32
}

pub class Open derives Base { }
pub class Der derives priv Base { }
pub class Pro derives prot Base { }

// The file of the edge names everything through it.
pub fn lib_reads() -> i32 {
    var a: Der::Inner
    var b: Pro::Inner
    var c: Open::Hidden
    var n: Der::Num = 0
    return a.k + b.k + c.k + n
}
