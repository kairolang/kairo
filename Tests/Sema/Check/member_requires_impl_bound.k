// A member's `requires P impl I`, P a parameter of its record, gives the
// member's body I's members on P, and is the member's C++ constraint: an
// instance whose argument does not conform has no such member, so its body
// is not instantiated there. Calling it on that instance is SC153E.
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
// RUN: { %kairo %s --type-check-only -DBAD 2>&1 || true; } | %FileCheck %s

interface Default {
    static fn make_default() -> Self
}

class Num {
    pub var n: i32

    fn Num(self) {
        self.n = 0
    }

    pub static fn make_default() -> Num {
        var x = Num()
        x.n = 7
        return x
    }
}

class NoDef {
    pub var n: i32

    fn NoDef(self) {
        self.n = 1
    }
}

class <V> Holder {
    pub var v: V

    fn Holder(self, const v: V) {
        self.v = v
    }

    pub fn reset(self) -> *V requires V impl Default {
        self.v = V::make_default()
        return &self.v
    }

    pub fn op []= (self, const k: i32) -> *V requires V impl Default {
        self.v = V::make_default()
        return &self.v
    }

    pub fn get(self) -> *V {
        return &self.v
    }
}

fn main() -> i32 {
    var h = Holder<Num>(Num())
    var p = h.reset()
    if p->n != 7 {
        return 1
    }

    h[2] = Num()
    var g = Holder<NoDef>(NoDef())
    var q = g.get()
    eval if defined!(BAD) {
        // CHECK: member_requires_impl_bound.k:[[@LINE+1]]:17: error [SC153E]: 'reset' cannot be called on 'Holder<NoDef>': its 'requires' clause does not hold
        var r = g.reset()
        // CHECK: note [SC153N]: 'NoDef' does not conform to 'Default'
    }

    return q->n - 1
}
