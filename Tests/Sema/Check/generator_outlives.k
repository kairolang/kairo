// A generator kept longer than the object it was created from dangles
// (functions-generators.mdx, Generator lifetimes: `var it =
// make_list().gen()` reads a destroyed list); Tether reports it.
//
// XFAIL: *
// Ticket "[Sema/Tether] A generator that outlives its object or `@inout`
// argument is not diagnosed" (private/IMPORTANT/TICKETS.TXT, 2026-10-26).
// Today it compiles and runs against a destroyed temporary (status.mdx, Not
// Diagnosed; waits on Tether covering generators). The code is not decided;
// the check asks for an error at the marked line. When it XPASSes, delete the
// XFAIL and pin the code and message.

class L {
    pub var n: i32 = 3
    fn gen(const self) -> yield i32 {
        for i in 0..self.n { yield i }
    }
}

fn make() -> L { return L() }

fn main() -> i32 {
    var it = make().gen()
// CHECK: generator_outlives.k:[[@LINE-1]]:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
    var s = 0
    for x in it { s += x }
    return s
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
