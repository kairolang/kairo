// A generic body's transfer out of a pointee or a part of `self` moves at an
// instance whose type cannot be copied, so a read of the same storage before
// it is assigned again is a use after move there (SC052E), reported at the
// instance's use with the generic's lines as notes. Out of a const place it
// copies, which such an instance cannot do (SC182E). A COPY instance of the
// same body is accepted, and so is a reread after a reassignment.

class M {
    pub var k: u64
    pub fn M(self, k: u64) { self.k = k }
    @move pub fn M(self, other: Self) = default
}

class <T> Box {
    pub var v: T
    pub fn Box(self, v: T) { self.v = v }
    pub fn again(self) -> u64 {
        var a: T = self.v
        var b: T = self.v
        return 0
    }
}

// In an extension: judged at each use, as a generic function is.
extend <T> Box<T> {
    fn again_ext(self) -> u64 {
        var a: T = self.v
        var b: T = self.v
        return 0
    }
}

fn <T> twice(p: unsafe *T) -> u64 {
    unsafe {
        var t: T = *p
        var u: T = *p
    }

    return 0
}

fn <T> from_const(p: unsafe *const T) -> u64 {
    unsafe {
        var t: T = *p
    }

    return 0
}

fn <T> refill(p: unsafe *T, v: T) -> u64 {
    unsafe {
        var t: T = *p
        *p = v
        var u: T = *p
    }

    return 0
}

fn main() -> i32 {
    var m = M(1)
    var i = 2
    twice<M>(unsafe &m)
    twice<i32>(unsafe &i)
    from_const<M>(unsafe &m)
    from_const<i32>(unsafe &i)
    refill<M>(unsafe &m, M(3))
    refill<i32>(unsafe &i, 4)
    var bm = Box<M>(M(5))
    var bi = Box<i32>(6)
    return (bi.again() + bi.again_ext() + bm.again_ext() + bm.v.k) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: dependent_pointee_reuse.k:63:5: error [SC052E]: '*p' is used after being moved in 'twice<M>': 'M' cannot be copied, so the transfer moves it
// CHECK: dependent_pointee_reuse.k:35:20: note [I900N]: '*p' was moved here, as a 'M'
// CHECK: dependent_pointee_reuse.k:36:21: note [I900N]: and used again here
// CHECK: dependent_pointee_reuse.k:65:5: error [SC182E]: cannot copy a value of type 'M' in 'from_const<M>': '*p' is const, so the transfer cannot move it
// CHECK: dependent_pointee_reuse.k:44:20: note [I900N]: '*p' is copied here, as a 'M'
// CHECK: dependent_pointee_reuse.k:69:14: error [SC052E]: 'self.v' is used after being moved in 'Box<M>': 'M' cannot be copied, so the transfer moves it
// CHECK: dependent_pointee_reuse.k:18:20: note [I900N]: 'self.v' was moved here, as a 'M'
// CHECK: dependent_pointee_reuse.k:19:20: note [I900N]: and used again here
// CHECK: dependent_pointee_reuse.k:71:43: error [SC052E]: 'self.v' is used after being moved in 'again_ext<M>': 'M' cannot be copied, so the transfer moves it
// CHECK: dependent_pointee_reuse.k:27:20: note [I900N]: 'self.v' was moved here, as a 'M'
// CHECK: dependent_pointee_reuse.k:28:20: note [I900N]: and used again here
// CHECK-NOT: error
