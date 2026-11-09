// A call made through a duck parameter (`self.dyn()->...`) to a function
// with default parameters was emitted without the defaulted arguments, since the
// fill happens at the call site and the dependent path skipped it (clang: "too
// few arguments to function call").

class Rep {
    var n: i32;
    fn first(self, k: i32, extra: i32 = 100) -> unsafe *Rep { self.n = k + extra; return unsafe &self; }
    fn make(self, a: i32, b: i32 = 5) -> Rep { var r: Rep; r.n = a + b; return r; }
}

fn free_def(a: i32, b: i32 = 3) -> i32 { return a * b; }

class <T: type> Mix {
    inline fn dyn(self) -> unsafe *T { return unsafe (&self as *T); }
    fn go(self) -> i32 {
        var a = free_def(2);
        self.dyn()->rep.first(1);
        var m = self.dyn()->rep.make(1);
        var c = self.dyn()->mk().first(2)->n;
        return a + self.dyn()->rep.n + m.n + c;
    }
}

class Host derives Mix<Host> {
    var rep: Rep;
    fn mk(self) -> Rep { var r: Rep; return r; }
}

fn main() -> i32 {
    var h: Host;
    // a=6, rep.n=101, m.n=6, c=102
    if h.go() != 215 { return 1; }
    return 0;
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: { %kairo -fduck-generics %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: %t.exe
