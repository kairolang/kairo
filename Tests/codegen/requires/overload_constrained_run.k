// Among generic overloads tied after partial ordering, the more constrained
// one wins, as in C++ ([temp.func.order]/6, [temp.constr.order]): a clause
// beats no clause, an inline bound counts as its clause, and a clause whose
// normal form subsumes the other's (`A && B` over `A`, `A` over `A || B`)
// beats it. Each clause is in the emitted template head, so clang orders the
// same overloads by the same rule; the program exits 0 only when every call
// picked the overload Kairo picked.

interface Shout {
    fn shout(const self) -> i32
}

interface Wave {
    fn wave(const self) -> i32
}

class Loud {
    pub var n: i32
    pub fn Loud(self, n: i32) {
        self.n = n
    }

    pub fn shout(const self) -> i32 {
        return self.n
    }

    pub fn wave(const self) -> i32 {
        return 2
    }
}

class Plain {
    pub var n: i32
    pub fn Plain(self, n: i32) {
        self.n = n
    }
}

class OnlyWave {
    pub fn OnlyWave(self) {}

    pub fn wave(const self) -> i32 {
        return 3
    }
}

// A clause beats no clause.
fn <T> f(const x: T) -> i32 requires T impl Shout {
    return 1
}

fn <T> f(const x: T) -> i32 {
    return 2
}

// A conjunction beats one of its conjuncts.
fn <T> g(const x: T) -> i32 requires T impl Shout {
    return 10
}

fn <T> g(const x: T) -> i32 requires T impl Shout && T impl Wave {
    return 20
}

// An inline bound is a clause.
fn <T impl Shout> h(const x: T) -> i32 {
    return 100
}

fn <T> h(const x: T) -> i32 {
    return 200
}

// An atom beats a disjunction it is a side of.
fn <T> k(const x: T) -> i32 requires T impl Shout || T impl Wave {
    return 1000
}

fn <T> k(const x: T) -> i32 requires T impl Shout {
    return 2000
}

// The bound and the clause spell the same constraint, and a conjunction
// written over two parameters orders like one over one.
fn <A impl Shout, B> m(const a: A, const b: B) -> i32 {
    return 10000
}

fn <A, B> m(const a: A, const b: B) -> i32 requires A impl Shout && B impl Wave {
    return 20000
}

fn main() -> i32 {
    var l = Loud(1)
    var p = Plain(1)
    var w = OnlyWave()
    var t = f(l) + f(p)              // 1 + 2
    t += g(l)                        // 20 (Loud has both)
    t += h(l) + h(p)                 // 100 + 200
    t += k(l) + k(w)                 // 2000 + 1000
    t += m(l, w) + m(l, p)           // 20000 + 10000
    return t - 33323
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-DAG: template<class T> requires( {{.*}}Shout_c<T>) signed int f(T const & x) noexcept;
// IR-DAG: template<class T> signed int f(T const & x) noexcept;
// IR-DAG: template<class T> requires( {{.*}}Shout_c<T> && {{.*}}Wave_c<T>) signed int g(T const & x) noexcept;
// IR-DAG: template<class T> requires((( {{.*}}Shout_c<T>) ||( {{.*}}Wave_c<T>))) signed int k(T const & x) noexcept;
// IR-DAG: template<class A, class B> requires( {{.*}}Shout_c<A> && {{.*}}Wave_c<B>) signed int m(A const & a, B const & b) noexcept;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
