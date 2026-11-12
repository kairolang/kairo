// RUN: %kfmt --stdout %s | diff -u %S/Expected/subscript_set.k -
// RUN: %kfmt --check %S/Expected/subscript_set.k
//
// `op []=`, the place subscript (P880), prints back as written: three
// tokens with the `=` touching the `]`, in a class body, an interface and
// an out-of-line definition, and as an explicit call step (`b.op []=(1)`).
// An expression `b[0]= 4` is an assignment, spaced as one.

class Buf {
    var d: [i32; 4]
    fn Buf(self) { }
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
}

interface Store {
    fn op []= (self, i: usize) -> *i32
}

fn Buf::op []= (self, i: u8) -> *i32 { return &self.d[0] }

fn main() -> i32 {
    var b = Buf()
    b[0]= 4
    var p = b.op []=(1)
    return 0
}
