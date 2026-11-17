// A `requires X impl I` conjunct gives the body I's members on X, exactly as
// a bound in the parameter list does, wherever the clause stands: on a
// member (X a parameter of its record), on an extension member, on the
// class, on an extension header, and on a free function. X may be an
// associated type (`J::Item impl Eq`), I a generic interface, and the
// conjunct may sit beside others, `__builtin_is_same` included. The members
// are reachable however the receiver's type is reached: a field read
// through a pointer, a local, a call's result, an operator's operand.

interface Same {
    fn same(const self, const o: Self) -> bool
}

interface Less {
    fn op <(const self, const o: Self) -> bool
}

interface Eq {
    fn op ==(const self, const o: Self) -> bool
}

interface Zero {
    fn zero() -> Self
}

interface <U> From {
    fn from(const u: U) -> Self
}

interface Src {
    type Item
    fn next(self) -> Self::Item
}

fn <U impl Same> same_twice(const a: U) -> bool { return a.same(a) }

class <T> V {
    var p: unsafe *T

    // Through a pointer read, a local and a call's result.
    fn deref(const self, const v: T) -> bool requires T impl Same { return unsafe (*self.p).same(v) }

    fn local(const self, const v: T) -> bool requires T impl Same {
        var w = unsafe (*self.p)
        return w.same(v)
    }

    // An operator, a static, a conjunction of two.
    fn lt(const self, const a: T, const b: T) -> bool requires T impl Less { return a < b }

    fn ne(const self, const a: T, const b: T) -> bool requires T impl Eq { return a != b }

    fn fresh(const self, const a: T) -> bool requires T impl Zero && T impl Same {
        return T::zero().same(a)
    }

    // A bounded function called with the clause's T.
    fn twice(const self, const a: T) -> bool requires T impl Same { return same_twice(a) }

    // A generic interface whose argument is the member's own parameter.
    fn <U> make(const self, const u: U) -> T requires T impl From<U> { return T::from(u) }

    // ... or the record's.
    fn <C> into(const self) -> C requires C impl From<T> { return C::from(unsafe (*self.p)) }

    // Equated with T, used through T's bound.
    fn <U> eq_to(const self, const u: U) -> bool requires __builtin_is_same<U, T>() && T impl Same {
        return unsafe (*self.p).same(u)
    }

    // Unbounded beside the bounded ones.
    fn get(const self) -> T { return unsafe (*self.p) }
}

extend <T> V<T> {
    fn ext_deref(const self, const v: T) -> bool requires T impl Same { return unsafe (*self.p).same(v) }
}

extend <T> V<T> requires T impl Less {
    fn ext_hdr(const self, const v: T) -> bool { return unsafe (*self.p) < v }
}

class <T> W requires T impl Same {
    var p: unsafe *T

    fn deref(const self, const v: T) -> bool { return unsafe (*self.p).same(v) }
}

// Associated types: on a member (J the record's), an extension header and
// a free function.
class <J> Pull {
    var j: J

    fn two(self) -> bool requires J impl Src && J::Item impl Eq {
        var x = self.j.next()
        return x == self.j.next()
    }
}

extend <J> Pull<J> requires J impl Src && J::Item impl Same {
    fn two_same(self) -> bool {
        var x = self.j.next()
        return x.same(self.j.next())
    }
}

fn <J impl Src> first_two(j: J) -> bool requires J::Item impl Eq {
    var x = j.next()
    return x == j.next()
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not="error [" --implicit-check-not="warning ["
