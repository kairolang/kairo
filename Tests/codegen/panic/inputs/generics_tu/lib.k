// A generic panicking function and a generic interface, instantiated only
// by the importer (generics_tu.k).
pub struct Oops { pub var n: i32 }

pub interface <E> Src {
    fn read(self) panic(E) -> i32
}

pub fn <T> pick(x: T, flag: bool) panic(T, Oops) -> i32 {
    if flag { panic x }
    panic Oops { n: 7 }
}

pub fn <E, T impl Src<E>> through(t: T) panic -> i32 {
    return t.read() + 1
}
