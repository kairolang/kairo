// O17: a call to an overloaded Kairo free function (`is_rec(x)`, two
// candidates) whose argument is deduced from a duck call (`x` of a
// `<T: type>` type) cannot be picked until an instance fixes the argument.
// EmitIR used to ICE "unpromoted callee"; it now goes out as written and
// clang picks the overload per instance. A local initialised from a call
// with such an argument (`var prec = self.prec_of(cur)`) is `auto`, not an
// "no inferred type" I011W.

class Ex { pub var k: i32 = 0 }
class St { pub var k: i32 = 1 }

pub fn is_rec(p: unsafe *Ex) -> bool { return p->k == 7; }
pub fn is_rec(p: unsafe *St) -> bool { return p->k == 7; }

enum Prec derives u8 { A, B }

class Host derives Mixin<Host> {
    pub var e: Ex;
    pub fn parse_type(self) -> unsafe *Ex { return unsafe (&self.e); }
    pub fn kind(self) -> i32 { return 3; }
}

class <T: type> Mixin {
    inline fn dyn(self) -> unsafe *T { return unsafe ((unsafe &self) as unsafe *T); }
    priv fn prec_of(self, k: i32) -> Prec { if k > 2 { return Prec::B; } return Prec::A; }
    pub fn go(self) -> bool {
        var cur = self.dyn()->kind();
        var prec = self.prec_of(cur);
        var rty = self.dyn()->parse_type();
        if rty == &null || is_rec(rty) { return false; }
        return (prec as u8) > (Prec::A as u8);
    }
}

fn main() -> i32 {
    var h = Host();
    if !h.go() { return 1 }
    h.e.k = 7;
    if h.go() { return 2 }
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: I011W
// DIAG-NOT: I003E
// RUN: %t.exe
