// Fixture for const_value_params.k: generic value parameters in the old
// `const` spelling, beside every shape the rewrite must leave alone.
// A comment naming <const N: usize> stays as written.

class <const N: usize> Buf {
    pub var data: [i32; N]
}

struct <T, const M: i32, U> Mixed {
    pub var t: T
    pub var u: U
}

fn <const K: usize> width(b: *Buf<K>) -> usize { return K }

class <const A: usize> Outer {
    fn <const B: usize> both(self) -> usize { return A + B }
}

fn <T, const  N :usize> count(x: T) -> usize { return N }

fn keep(const x: i32) -> i32 {
    var s = "fn <const N: usize> g"
    return x
}

fn main() -> i32 { return 0 }
