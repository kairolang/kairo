// Before a constructor has initialized its own fields, a field of a base is
// only what the constructor itself assigned: reading one it has not assigned
// on every path, changing one in place and writing part of one are SC175E.
// A whole write is accepted, and a base's const or array field is no more
// assignable here than anywhere else.

class Q {
    pub var n: i32
    fn Q(self, n: i32) { self.n = n }
}

class Base {
    pub var ctx: i32 = 7
    pub var arr: [i32; 2] = [1, 2]
    pub var pt: Q = Q(0)
    pub const k: i32 = 3
    fn bump(self) { self.ctx += 1 }
}

class Read derives Base {
    pub var q: Q
    fn Read(self) {
        var t = self.ctx
        self.q = Q(t)
    }
}

class Branch derives Base {
    pub var q: Q
    fn Branch(self, v: i32) {
        if v > 0 { self.ctx = v }
        self.q = Q(self.ctx)
    }
}

class Compound derives Base {
    pub var q: Q
    fn Compound(self, v: i32) {
        self.ctx += v
        self.q = Q(2)
    }
}

class Part derives Base {
    pub var q: Q
    fn Part(self, v: i32) {
        self.arr[0] = v
        self.pt.n = v
        self.q = Q(2)
    }
}

class Call derives Base {
    pub var q: Q
    fn Call(self) {
        self.bump()
        self.q = Q(2)
    }
}

class Whole derives Base {
    pub var q: Q
    fn Whole(self, v: i32) {
        self.arr = [v, v]
        self.k = v
        self.q = Q(2)
    }
}

// Accepted: a whole write, a read after it, and anything once the last own
// field is initialized.
class Fine derives Base {
    pub var q: Q
    fn Fine(self, v: i32) {
        self.ctx = v
        self.q = Q(self.ctx)
        self.ctx += self.arr[0]
        self.arr[1] = self.ctx
        self.bump()
    }
}

// A write of the base's field does not stand in for the own field's: one
// initialized on one branch only is still SC173E.
class Half derives Base {
    pub var q: Q
    fn Half(self, c: bool) {
        self.ctx = 1
        if c { self.q = Q(1) }
    }
}

fn main() -> i32 {
    var f = Fine(1)
    return f.ctx - 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=NOICE
// NOICE-NOT: I003E
// NOICE-NOT: internal compiler error

// CHECK:     ctor_inherited_field.k:23:17: error [SC175E]: 'ctx' cannot be read before the constructor has initialized its fields
// CHECK:     ctor_inherited_field.k:32:20: error [SC175E]: 'ctx' is read before it is initialized on every path
// CHECK:     ctor_inherited_field.k:39:9: error [SC175E]: 'ctx' is read before it is initialized on every path
// CHECK:     ctor_inherited_field.k:47:9: error [SC175E]: 'arr' cannot be read before the constructor has initialized its fields
// CHECK:     ctor_inherited_field.k:48:9: error [SC175E]: 'pt' cannot be read before the constructor has initialized its fields
// CHECK:     ctor_inherited_field.k:56:9: error [SC175E]: 'self' is used before the constructor has initialized its fields
// CHECK:     ctor_inherited_field.k:64:9: error [SC071E]: an array is not assignable
// CHECK:     ctor_inherited_field.k:65:9: error [SC171E]: cannot assign to const field 'k'
// CHECK-NOT: ctor_inherited_field.k:7{{[0-9]}}:{{.*}}error
// CHECK:     ctor_inherited_field.k:87:8: error [SC173E]: field 'q' is not initialized on every path through the constructor of 'Half'
