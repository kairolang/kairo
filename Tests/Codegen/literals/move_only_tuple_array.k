// A tuple literal and a fixed-array literal are initialized element by
// element, so an element that cannot be copied is moved in: a named value
// is moved from, a temporary is built in place. Nested arrays, and a vector
// of tuples, follow from the same rule.

static moved: i32 = 0

class M {
    pub var n: i32
    pub fn M(self) { self.n = 0 }
    pub fn M(self, n: i32) { self.n = n }
    @move pub fn M(self, other: Self) { self.n = other.n; other.n = -1; moved += 1 }
}

fn pair(m: M) -> (M, i32) { return (m, 7) }

fn main() -> i32 {
    var m = M(4)
    var t = (m, 1)
    if t.0.n != 4 || t.1 != 1 || moved != 1 { return 1 }

    var p = pair(M(5))
    if p.0.n != 5 || p.1 != 7 { return 2 }

    moved = 0
    var a = M(8)
    var xs: [M; 2] = [a, M(9)]
    if xs[0].n != 8 || xs[1].n != 9 || moved != 1 { return 3 }

    var b = M(20)
    var nested: [[M; 1]; 2] = [[b], [M(21)]]
    if nested[0][0].n != 20 || nested[1][0].n != 21 { return 4 }

    var c = M(30)
    var tv: [(M, i32)] = [(c, 1), (M(31), 2)]
    if tv.size() != 2 || tv[0].0.n != 30 || tv[1].0.n != 31 || tv[1].1 != 2 { return 5 }

    // A tuple that is a match's scrutinee is never built: nothing leaves
    // its elements, and `d` is live after the match.
    var d = M(40)
    var q = match (d.n, p.1) {
        case (40, 7) => 0
        default => 1
    }
    return q + d.n - 40
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
