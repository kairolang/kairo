// A plain `for` binder over a tuple yield's pointer part
// (`-> yield (*const K, *const V)`) whose type cannot be copied borrows what
// the part points at, read-only, as a `const` binder does: no copy and no
// error. `var (x, y) = t` over a named tuple of MOVE parts moves the tuple,
// so a later read of it is SC052E. `case var v` of a type that cannot be
// copied reads what it matched in place, as `case const v` does.

class Str {
    pub var n: i32 = 0
    pub fn Str(self, n: i32) { self.n = n }
    @move pub fn Str(self, other: Self) { self.n = other.n; other.n = -1 }
}

class Table {
    pub var k: Str
    pub var v: Str
    pub fn Table(self) { self.k = Str(1); self.v = Str(2) }

    pub fn op in (const self) -> yield (*const Str, *const Str) {
        yield (&self.k, &self.v)
    }
}

fn one() -> Str? { return Str(4) }

fn main() -> i32 {
    var sum = 0
    var t   = Table()
    for (k, const v) in t {
        sum += k.n + v.n
    }

    for (const *k, const *v) in t {
        sum += k->n + v->n
    }

    var pair = (Str(1), Str(2))
    var (a, b) = pair
    sum += a.n + b.n + pair.0.n

    var o? = one()
    match o {
        case null { sum += 1 }
        case var s { sum += s.n }
    }

    return sum
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT:  error
// CHECK-NOT:  :33:{{[0-9]+}}: error
// CHECK:      :39:24: error [SC052E]: 'pair' is used after being moved
// CHECK-NEXT: :38:18: note [I900N]: 'pair' was moved here, into the destructured binders
// CHECK-NOT:  error [
