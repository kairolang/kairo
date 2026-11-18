// What a `requires X impl I` clause grants is I's members on X in that
// body only: a member of an interface not in the clause is still R025E,
// a sibling member with no clause still sees an opaque T (R051E), and a
// bounded function needing an interface the clause does not name is
// refused. At a call, an argument that does not meet the clause is SC153E,
// for a plain member, a generic member, an extension member, and a
// conjunct on an associated type.

interface Same {
    fn same(const self, const o: Self) -> bool
}

interface Zero {
    fn zero() -> Self
}

interface <U> From {
    fn from(const u: U) -> Self
}

interface Eq {
    fn op ==(const self, const o: Self) -> bool
}

interface Src {
    type Item
    fn next(self) -> Self::Item
}

fn <U impl Same> same_twice(const a: U) -> bool { return a.same(a) }

class <T> V {
    var p: unsafe *T

    fn not_in(const self, const v: T) -> bool requires T impl Zero { return v.same(v) }

    fn unbounded(const self, const v: T) -> bool { return unsafe (*self.p).same(v) }

    fn forward(const self, const v: T) -> bool requires T impl Zero { return same_twice(v) }

    fn fill(self) requires T impl Zero { unsafe { *self.p = T::zero() } }

    fn <U> set(self, const u: U) requires T impl From<U> { unsafe { *self.p = T::from(u) } }
}

extend <T> V<T> {
    fn ext_same(const self, const v: T) -> bool requires T impl Same { return unsafe (*self.p).same(v) }
}

class Opaque {
    pub var n: i32 = 0
}

class Gen {
    pub var n: i32 = 0
}

extend Gen impl Src {
    type Item = Opaque
    fn next(self) -> Opaque { return Opaque{} }
}

class <J> Pull {
    var j: J

    fn two(self) -> bool requires J impl Src && J::Item impl Eq {
        var x = self.j.next()
        return x == self.j.next()
    }
}

fn main() -> i32 {
    var o = Opaque{}
    var v = V<Opaque>{p: unsafe &o}
    v.fill()
    v.set(1)
    var s = v.ext_same(o)
    var q = Pull<Gen>{j: Gen{}}
    var t = q.two()
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:35:79: error [R025E]: no member named 'same' in the bounds of 'T'
// DIAG: {{.*}}:37:76: error [R051E]: 'T' has no members, so 'same' cannot be resolved
// DIAG-NEXT: {{.*}}:32:8: note [R051N]: 'T' is declared with no bound; add 'impl <Interface>' to give it members
// DIAG: {{.*}}:39:78: error [R025E]: 'same_twice' needs 'T' to implement 'Same'; none of the bounds of 'T' does
// DIAG-NEXT: {{.*}}:30:5: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:32:8: note [I900N]: 'T' is declared here; bound it 'impl Same' too, or by an interface that derives it
// DIAG: {{.*}}:75:5: error [SC153E]: 'fill' cannot be called on 'V<Opaque>': its 'requires' clause does not hold
// DIAG-NEXT: {{.*}}:41:28: note [SC153N]: 'Opaque' does not conform to 'Zero'
// DIAG: {{.*}}:76:5: error [SC153E]: 'set' cannot be called on 'V<Opaque>': its 'requires' clause does not hold
// DIAG-NEXT: {{.*}}:43:43: note [SC153N]: 'Opaque' does not conform to 'From<i32>'
// DIAG: {{.*}}:77:13: error [SC153E]: 'ext_same' cannot be called on 'V<Opaque>': its 'requires' clause does not hold
// DIAG-NEXT: {{.*}}:47:58: note [SC153N]: 'Opaque' does not conform to 'Same'
// DIAG: {{.*}}:79:13: error [SC153E]: 'two' cannot be called on 'Pull<Gen>': its 'requires' clause does not hold
// DIAG-NEXT: {{.*}}:66:49: note [SC153N]: 'Opaque' does not conform to 'Eq'
// END-GENERATED-CHECKS(DIAG)
