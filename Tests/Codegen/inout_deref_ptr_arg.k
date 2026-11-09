// An `@inout` argument that is `*p` (marked `&`), followed by an
// argument with an effect, is sequenced; the sequencing must bind the pointee
// itself, not a copy that the callee's `T&` parameter then cannot bind.
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe

class Inv { pub var n: i32; }
class BE { fn triple(self) -> string { return "x"; } }
class Holder {
    var inv_: Inv;
    fn invocation(self) -> unsafe *Inv { return unsafe &self.inv_; }
    fn run(self, be: unsafe *BE) -> i32 {
        var a = bump(&*self.invocation(), be->triple(), 2);
        var inv = self.invocation();
        var b = bump(&*inv, be->triple(), 3);
        return a + b;
    }
}
fn bump(@inout inv: Inv, tag: string, k: i32) -> i32 { inv.n += k; return inv.n; }
fn main() -> i32 {
    var b = BE {};
    var h = Holder { inv_: Inv { n: 1 } };
    if h.run(unsafe &b) == 9 && h.inv_.n == 6 { return 0; }
    return 1;
}
