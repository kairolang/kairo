// A field, a tuple element or an array element is part of its object, so
// through a const object it is const (variables.mdx, "The `const` Binding
// Rule"; classes.mdx, "Const Methods"): a write to it is SC071E naming the
// binding, with the `var` fix-it on a local, for `=`, `op=`, `++` and `--`,
// at any depth, through a const local, parameter or global and through a
// `*const T`. A non-const method on such a field is SC063E, and its address
// is a `*const`. `writable` holds what const does not reach.

class In {
    pub var w: i32 = 0
    pub fn set(self) { self.w = 1 }
    pub fn get(const self) -> i32 { return self.w }
}

class C {
    pub var v: i32 = 0
    pub var inn: In = In()
    pub var xs: [i32; 3] = [1, 2, 3]
    pub var items: [i32] = [1, 2]
    pub var p: unsafe *i32 = &null
    pub var q: unsafe *C = &null
    pub mutable var m: i32 = 0
    pub static count: i32 = 0
}

struct S { var a: i32 = 0 }

const g = C()

fn params(const c: C, const s: S) {
    c.v = 1
    s.a = 2
}

fn locals() {
    const c = C()
    c.v = 3
    c.inn.w = 4
    c.xs[0] = 1
    c.v += 1
    c.v++
    --c.inn.w
    c.items[0] = 4
    g.v = 1
}

fn tuples_and_arrays() {
    const t = (1, 2)
    t.0 = 5
    const arr: [In; 2] = [In(), In()]
    arr[0].w = 2
}

fn pointee(ok: *C) {
    var pc: *const C = ok
    pc->v = 1
    pc->inn.w = 1
    (*pc).v = 2
}

fn subobject_methods() -> i32 {
    const c = C()
    c.inn.set()
    c.items.push(1)
    var p: *i32 = &c.v
    return c.inn.get() + *p
}

// What stays writable: a `mutable var` field, a static, the pointee of a
// pointer the const object holds, and the pointee of a const pointer
// binding (`const b: *T` cannot be re-pointed; its pointee is not const).
fn writable(ok: *C) -> i32 {
    const c = C()
    c.m = 5
    c.count = 4
    C::count = 5
    var x = 1
    const d = C()
    unsafe {
        *d.p = 7
        d.q->v = 3
    }
    const b: *C = ok
    b->v = 9
    b->inn.w = 9
    b->inn.set()
    var free = C()
    free.v = 1
    free.inn.w = 2
    free.xs[0] = 3
    var copy = c.inn
    copy.w = 7
    return x
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: {{.*}}const_object_field_write.k:31:5: error [SC071E]: cannot assign to a field of 'c': 'c' is const
// CHECK-NEXT: {{.*}}const_object_field_write.k:30:17: note [I900N]: 'c' declared const here
// CHECK: {{.*}}const_object_field_write.k:32:5: error [SC071E]: cannot assign to a field of 's': 's' is const
// CHECK-NEXT: {{.*}}const_object_field_write.k:30:29: note [I900N]: 's' declared const here
// CHECK: {{.*}}const_object_field_write.k:37:5: error [SC071E]: cannot assign to a field of 'c': 'c' is const
// CHECK-NEXT: fix-it:{{.*}}:{36:5-36:10}:"var"
// CHECK-NEXT: {{.*}}const_object_field_write.k:36:11: note [I900N]: 'c' declared const here
// CHECK: {{.*}}const_object_field_write.k:38:5: error [SC071E]: cannot assign to a field of 'c': 'c' is const
// CHECK: {{.*}}const_object_field_write.k:36:11: note [I900N]: 'c' declared const here
// CHECK: {{.*}}const_object_field_write.k:39:5: error [SC071E]: cannot assign to an element of 'c': 'c' is const
// CHECK: {{.*}}const_object_field_write.k:36:11: note [I900N]: 'c' declared const here
// CHECK: {{.*}}const_object_field_write.k:40:5: error [SC071E]: cannot update a field of 'c': 'c' is const
// CHECK: {{.*}}const_object_field_write.k:36:11: note [I900N]: 'c' declared const here
// CHECK: {{.*}}const_object_field_write.k:41:5: error [SC071E]: cannot increment or decrement a field of 'c': 'c' is const
// CHECK: {{.*}}const_object_field_write.k:36:11: note [I900N]: 'c' declared const here
// CHECK: {{.*}}const_object_field_write.k:42:5: error [SC071E]: cannot increment or decrement a field of 'c': 'c' is const
// CHECK: {{.*}}const_object_field_write.k:36:11: note [I900N]: 'c' declared const here
// CHECK: {{.*}}const_object_field_write.k:43:5: error [SC071E]: cannot assign to an element of 'c': 'c' is const
// CHECK: {{.*}}const_object_field_write.k:36:11: note [I900N]: 'c' declared const here
// CHECK: {{.*}}const_object_field_write.k:44:5: error [SC071E]: cannot assign to a field of 'g': 'g' is const
// CHECK: {{.*}}const_object_field_write.k:28:7: note [I900N]: 'g' declared const here
// CHECK: {{.*}}const_object_field_write.k:49:5: error [SC071E]: cannot assign to a field of 't': 't' is const
// CHECK: {{.*}}const_object_field_write.k:48:11: note [I900N]: 't' declared const here
// CHECK: {{.*}}const_object_field_write.k:51:5: error [SC071E]: cannot assign to a field of 'arr': 'arr' is const
// CHECK: {{.*}}const_object_field_write.k:50:11: note [I900N]: 'arr' declared const here
// CHECK: {{.*}}const_object_field_write.k:56:5: error [SC071E]: cannot assign to a field of '*pc': 'pc' points to const
// CHECK: {{.*}}const_object_field_write.k:55:9: note [I900N]: 'pc' declared as a pointer to const here
// CHECK: {{.*}}const_object_field_write.k:57:5: error [SC071E]: cannot assign to a field of '*pc': 'pc' points to const
// CHECK: {{.*}}const_object_field_write.k:55:9: note [I900N]: 'pc' declared as a pointer to const here
// CHECK: {{.*}}const_object_field_write.k:58:6: error [SC071E]: cannot assign to a field of '*pc': 'pc' points to const
// CHECK: {{.*}}const_object_field_write.k:55:9: note [I900N]: 'pc' declared as a pointer to const here
// CHECK: {{.*}}const_object_field_write.k:63:5: error [SC063E]: no matching overload for call to 'set'
// CHECK: {{.*}}const_object_field_write.k:11:9: note [I900N]: candidate not viable: 'set' is not const; it cannot be called on a const object
// CHECK: {{.*}}const_object_field_write.k:64:5: error [SC063E]: no matching overload for call to 'push'
// CHECK: {{.*}}const_object_field_write.k:65:19: error [SC028E]: cannot convert '*const i32' to '*i32'
