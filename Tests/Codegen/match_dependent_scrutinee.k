// O7: a match whose scrutinee is a call through a duck-generic mixin's
// `dyn()` (`unsafe *T`) has no type in the generic, so nothing lowered it and
// EmitIR met a MatchStmt ("match MatchLowering left in place"). The arms test
// constants of one enum, which is the column; the match lowers in the generic
// and each instance runs it.

enum Tk { A, B, C }

class Host {
    pub var k: Tk;
    fn Host(self, k: Tk) { self.k = k; }
    fn kind(self) -> Tk { return self.k; }
}

class <T: type> Mix {
    priv inline fn dyn(self) -> unsafe *T { return unsafe ((unsafe &self) as unsafe *T); }
    fn pick(self) -> i32 {
        match self.dyn()->kind() {
            case Tk::A { return 10; }
            case Tk::B { return 20; }
            default { return 30; }
        }
    }
}

class Probe { fn Probe(self) {} fn kind(self) -> Tk { return Tk::B; } }

fn main() -> i32 {
    var m: Mix<Probe>;
    if m.pick() != 20 { return 1; }
    return 0;
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
