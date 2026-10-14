// Passing a MOVE value moves it, and an imported `T&&` is the `@move` the
// call moves into: `v.push_back(m)` takes push_back(T&&), so `m` is
// moved-from afterwards. A COPY value binds push_back(const T&) and stays
// live, however often it is passed.

ffi "c++" import "vector"

class Mv {
    pub var n: i32 = 0
    fn Mv(self, n: i32) { self.n = n }
    @move fn Mv(self, other: Self) { self.n = other.n; other.n = 0 }
}

class Cp {
    pub var n: i32 = 0
    fn Cp(self, n: i32) { self.n = n }
}

fn moved() -> i32 {
    var v: cxx::std::vector<Mv>
    var m = Mv(5)
    v.push_back(m)
    return m.n
// DIAG: cxx_rref_arg.k:[[@LINE-1]]:12: error [SC052E]: 'm' is used after being moved
// DIAG: cxx_rref_arg.k:[[@LINE-3]]:17: note [{{[A-Z0-9]+}}]: 'm' was moved here, into a '@move' parameter
}

fn reassigned() -> i32 {
    var v: cxx::std::vector<Mv>
    var m = Mv(5)
    v.push_back(m)
    m = Mv(6)
    return m.n
}

fn copied() -> i32 {
    var c: cxx::std::vector<Cp>
    var k = Cp(3)
    c.push_back(k)
    c.push_back(k)
    return k.n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
