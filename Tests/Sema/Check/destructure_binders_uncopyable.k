// A plain binder that destructures a part of a value is a copy of that
// part: over a tuple yield's pointer part (`-> yield (*const K, *const V)`)
// a copy of what it points at. A part that cannot be copied is refused at
// the binder, with `const *k` as the fix. `var (x, y) = t` over a named
// tuple of MOVE parts moves the tuple, so a later read of it is SC052E.
// `case var v` is a copy of what it matched; `case const v` reads it.

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
// CHECK:      :29:10: error [SC182E]: cannot copy a value of type 'Str': it declares a move constructor and no copy constructor
// CHECK-NEXT: fix-it:"{{.*}}":{29:10-29:10}:"const *"
// CHECK-NEXT: :29:10: note [I900N]: the loop binder 'k' is a copy of its part of each element; bind 'const *k' for a pointer to it instead
// CHECK:      :29:13: error [SC182E]: cannot copy a value of type 'Str': it declares a move constructor and no copy constructor
// CHECK-NEXT: fix-it:"{{.*}}":{29:19-29:19}:"*"
// CHECK-NEXT: :29:13: note [I900N]: the loop binder 'v' is a copy of its part of each element; bind 'const *v' for a pointer to it instead
// CHECK-NOT:  :33:{{[0-9]+}}: error
// CHECK:      :39:24: error [SC052E]: 'pair' is used after being moved
// CHECK-NEXT: :38:18: note [I900N]: 'pair' was moved here, into the destructured binders
// CHECK:      :44:14: error [SC182E]: cannot copy a value of type 'Str': it declares a move constructor and no copy constructor
// CHECK-NEXT: fix-it:"{{.*}}":{44:14-44:17}:"const"
// CHECK-NEXT: :44:14: note [I900N]: the binder 'var s' is a copy of what it matched; 'const s' reads it in place
// CHECK-NOT:  error [
