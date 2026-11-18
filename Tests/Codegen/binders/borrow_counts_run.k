// A binder that borrows copies and moves nothing: over an array, a vector,
// a tuple element and a record's tuple `op in` (`(k, v)`), a plain binder of a move-only
// type and a `const` binder of any type read the element in place. A plain
// binder of a COPY type is still one copy per element.

var moves:  i32 = 0
var copies: i32 = 0

class Mv {
    pub var v: i32 = 0
    fn Mv(self, v: i32) { self.v = v }
    @move fn Mv(self, other: Self) {
        self.v = other.v
        moves += 1
    }
    fn get(const self) -> i32 { return self.v }
}

class Cp {
    pub var v: i32 = 0
    fn Cp(self, v: i32) { self.v = v }
    @copy fn Cp(self, const other: Self) {
        self.v = other.v
        copies += 1
    }
}

class Table {
    pub var k: Mv
    pub var v: Mv
    fn Table(self) { self.k = Mv(6); self.v = Mv(7) }

    fn op in (const self) -> yield (*const Mv, *const Mv) {
        yield (&self.k, &self.v)
    }
}

// One C++ template serves both instances: the binder copies at Cp and
// borrows at Mv.
fn <T> count(const xs: [T; 2]) -> i32 {
    var n = 0
    for x in xs { n += 1 }
    return n
}

fn main() -> i32 {
    var arr: [Mv; 3] = [Mv(1), Mv(2), Mv(3)]
    var vec: [Mv]
    vec.push(Mv(4))
    vec.push(Mv(5))
    var pairs: [(Mv, Mv); 1] = [(Mv(8), Mv(9))]
    var cps: [Cp; 2] = [Cp(1), Cp(2)]
    var table = Table()
    moves  = 0
    copies = 0

    var sum = 0
    for x in arr { sum += x.get() }
    for const x in arr { sum += x.v }
    for x in vec { sum += x.get() }
    for (a, b) in pairs { sum += a.v + b.v }
    for (k, v) in table { sum += k.v + v.get() }
    if moves != 0 { return 1 }

    for const c in cps { sum += c.v }
    if copies != 0 { return 2 }
    for c in cps {
        c.v += 10
        sum += c.v
    }

    if copies != 2 { return 3 }
    var two: [Mv; 2] = [Mv(1), Mv(2)]
    moves  = 0
    copies = 0
    if count(two) + count(cps) != 4 || moves != 0 || copies != 2 { return 5 }
    // 1+2+3, twice; 4+5; 8+9; 6+7; 1+2; 11+12.
    return if (sum == 12 + 9 + 17 + 13 + 3 + 23) => (0) else => 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT:   error [
// CXX-LABEL: int main() noexcept {
// CXX:       const{{ ?}}::{{.*}}Mv & x = 
// CXX:       const{{ ?}}::{{.*}}Cp & c = 
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=BIND
// BIND:      ::__kairo_bind_t<T> x = 
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
