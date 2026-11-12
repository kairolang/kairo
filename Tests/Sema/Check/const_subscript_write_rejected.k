// Sema dropped a subscript receiver's const before choosing its
// `op []`, so the `self` overload always won and every write through a const
// container passed --type-check-only; clang then picked the const overload
// from the real object and failed (CL001E). A const container offers
// only its `const self` subscript, an element of a const array or vector is
// a const place, and the write is SC071E naming the container.

class Buf {
    var a: [i32; 4]
    fn op [] (self, i: usize) -> *i32 { return &self.a[i] }
    fn op [] (const self, i: usize) -> *const i32 { return &self.a[i] }
}

// Only the mutable form: a const object has no subscript at all.
class OnlyMut {
    var a: [i32; 4]
    fn op [] (self, i: usize) -> *i32 { return &self.a[i] }
}

// Only the const form: even a mutable object reads a const place.
class OnlyConst {
    var a: [i32; 4]
    fn op [] (const self, i: usize) -> *const i32 { return &self.a[i] }
}

class P {
    var x: i32 = 0
    fn bump(self) { self.x += 1 }
}

class PB {
    var ps: [P; 2]
    fn op [] (self, i: usize) -> *P { return &self.ps[i] }
    fn op [] (const self, i: usize) -> *const P { return &self.ps[i] }
}

fn inc(@inout x: i32) { x += 1 }

fn writes() {
    const cb = Buf()
    cb[0] = 5
    cb[0] += 1
    ++cb[0]
    cb[1]--
    inc(&cb[0])
    var mp: *i32 = &cb[0]
    const pb = PB()
    pb[0].bump()
    const om = OnlyMut()
    var y = om[0]
    var oc = OnlyConst()
    oc[0] = 1
}

fn containers(const v: [i32], const s: string) {
    v[0] = 5
    v[1] += 1
    const ar: [i32; 3] = [1, 2, 3]
    ar[0] = 5
    s[0] = 65
}

fn nested(const g: [[i32]]) {
    g[0][1] = 2
}

fn loops(const v: [i32], const a: [i32; 3]) {
    for *e in v { *e = 0 }
    for *e in a { *e = 0 }
}

fn map_read(const m: {string: i32}) -> i32 {
    return m["a"]
}

fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: const_subscript_write_rejected.k:41:5: error [SC071E]: cannot assign to an element of 'cb': 'cb' is const
// CHECK: fix-it:{{.*}}:{40:5-40:10}:"var"
// CHECK: const_subscript_write_rejected.k:40:11: note [I900N]: 'cb' declared const here
// CHECK: const_subscript_write_rejected.k:42:5: error [SC071E]: cannot update an element of 'cb': 'cb' is const
// CHECK: fix-it:{{.*}}:{40:5-40:10}:"var"
// CHECK: const_subscript_write_rejected.k:40:11: note [I900N]: 'cb' declared const here
// CHECK: const_subscript_write_rejected.k:43:5: error [SC071E]: cannot increment or decrement an element of 'cb': 'cb' is const
// CHECK: fix-it:{{.*}}:{40:5-40:10}:"var"
// CHECK: const_subscript_write_rejected.k:40:11: note [I900N]: 'cb' declared const here
// CHECK: const_subscript_write_rejected.k:44:5: error [SC071E]: cannot increment or decrement an element of 'cb': 'cb' is const
// CHECK: fix-it:{{.*}}:{40:5-40:10}:"var"
// CHECK: const_subscript_write_rejected.k:40:11: note [I900N]: 'cb' declared const here
// CHECK: const_subscript_write_rejected.k:45:5: error [SC063E]: no matching overload for call to 'inc'
// CHECK: const_subscript_write_rejected.k:37:1: note [I900N]: candidate not viable: parameter 'x' is '@inout' and needs a mutable lvalue of type 'i32'; got 'const i32'
// CHECK: const_subscript_write_rejected.k:46:20: error [SC028E]: cannot convert '*const i32' to '*i32'
// CHECK: const_subscript_write_rejected.k:48:5: error [SC063E]: no matching overload for call to 'bump'
// CHECK: const_subscript_write_rejected.k:28:5: note [I900N]: candidate not viable: 'bump' is not const; it cannot be called on a const object
// CHECK: const_subscript_write_rejected.k:50:13: error [SC063E]: no matching overload for call to 'op []'
// CHECK: const_subscript_write_rejected.k:17:5: note [I900N]: candidate not viable: 'op []' is not const; it cannot be called on a const object
// CHECK: const_subscript_write_rejected.k:52:5: error [SC071E]: cannot assign to a const place
// CHECK: const_subscript_write_rejected.k:23:5: note [I900N]: 'op []' returns a const place here
// CHECK: const_subscript_write_rejected.k:56:5: error [SC071E]: cannot assign to an element of 'v': 'v' is const
// CHECK: const_subscript_write_rejected.k:55:21: note [I900N]: 'v' declared const here
// CHECK: const_subscript_write_rejected.k:57:5: error [SC071E]: cannot update an element of 'v': 'v' is const
// CHECK: const_subscript_write_rejected.k:55:21: note [I900N]: 'v' declared const here
// CHECK: const_subscript_write_rejected.k:59:5: error [SC071E]: cannot assign to an element of 'ar': 'ar' is const
// CHECK: fix-it:{{.*}}:{58:5-58:10}:"var"
// CHECK: const_subscript_write_rejected.k:58:11: note [I900N]: 'ar' declared const here
// CHECK: const_subscript_write_rejected.k:60:5: error [SC071E]: cannot assign to an element of 's': 's' is const
// CHECK: const_subscript_write_rejected.k:55:37: note [I900N]: 's' declared const here
// CHECK: const_subscript_write_rejected.k:64:5: error [SC071E]: cannot assign to an element of 'g': 'g' is const
// CHECK: const_subscript_write_rejected.k:63:17: note [I900N]: 'g' declared const here
// CHECK: const_subscript_write_rejected.k:68:19: error [SC071E]: cannot assign to '*e': 'e' points to const
// CHECK: const_subscript_write_rejected.k:68:10: note [I900N]: 'e' declared as a pointer to const here
// CHECK: const_subscript_write_rejected.k:69:19: error [SC071E]: cannot assign to '*e': 'e' points to const
// CHECK: const_subscript_write_rejected.k:69:10: note [I900N]: 'e' declared as a pointer to const here
// CHECK: const_subscript_write_rejected.k:73:12: error [SC063E]: no matching overload for call to 'op []'
// CHECK: {{.*}}hash_map.k:{{[0-9]+:[0-9]+}}: note [I900N]: candidate not viable: 'op []' is not const; it cannot be called on a const object
// CHECK-NOT: error
