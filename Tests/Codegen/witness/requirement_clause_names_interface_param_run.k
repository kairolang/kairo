// A requirement whose `requires` clause names its interface's own parameter
// (`from(it: J) requires __builtin_is_same<J::Item, T>()` in `interface <T>
// Build`). The witness of a conformer to `Build<i64>` is a C++
// specialization that declares no `T`: the clause is spelled there over the
// interface's arguments, `T` as `i64`, as the requirement's parameters and
// result are.

interface Source {
    type Item
    fn next(self) -> Self::Item?
}

interface <T> Build {
    static fn <J impl Source> from(it: J, hint: usize) -> Self requires __builtin_is_same<J::Item, T>()
}

class Count {
    var lo: i64
    var hi: i64

    pub fn Count(self, lo: i64, hi: i64) {
        self.lo = lo
        self.hi = hi
    }
}

extend Count impl Source {
    type Item = i64
    fn next(self) -> i64? {
        if self.lo == self.hi {
            return null
        }

        self.lo += 1
        return self.lo - 1
    }
}

class Total {
    pub var sum:  i64
    pub var hint: usize

    pub fn Total(self) {
        self.sum  = 0
        self.hint = 0
    }
}

extend Total impl Build<i64> {
    static fn <J impl Source> from(it: J, hint: usize) -> Total requires __builtin_is_same<J::Item, i64>() {
        var t = Total()
        t.hint = hint
        while true {
            var x = it.next()
            if !x? {
                break
            }

            t.sum += x
        }

        return t
    }
}

/// A generic conformer: each instance has a witness of its own, whose
/// clause reads the interface's `T` as that instance's `E`.
class <E> Pile {
    pub var last:  E
    pub var count: i64

    pub fn Pile(self, z: E) {
        self.last  = z
        self.count = 0
    }
}

extend <E> Pile<E> impl Build<E> {
    static fn <J impl Source> from(it: J, hint: usize) -> Pile<E> requires __builtin_is_same<J::Item, E>() {
        var first = it.next()
        var p     = Pile<E>(unwrap!(first))
        p.count = 1
        while true {
            var x = it.next()
            if !x? {
                break
            }

            p.last  = x
            p.count += 1
        }

        return p
    }
}

// Through the bound: the call goes to the witness.
fn <B impl Build<i64>> build(n: i64) -> B {
    return B::from(Count(1, n), n as usize)
}

fn main() -> i32 {
    var direct = Total::from(Count(1, 4), 3)
    var bound  = build<Total>(5)
    var pile   = build<Pile<i64>>(4)
    return (direct.sum - 6) as i32 + (direct.hint - 3) as i32 + (bound.sum - 10) as i32 + (pile.last - 3) as i32 + (pile.count - 3) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      template<> struct Build_witness<{{.*}}requirement_clause_names_interface_param_run::Total, signed long> {
// CXX-NEXT: kairo_rt_is_same<typename{{.*}}Source_witness<J>::Item, signed long>()
// CXX:      template<> struct Build_witness<{{.*}}Pile<signed long>, signed long> {
// CXX-NEXT: kairo_rt_is_same<typename{{.*}}Source_witness<J>::Item, signed long>()

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
