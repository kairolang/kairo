// A const fixed array, and one reached through a const path (a `const`
// parameter, a field through `const self`, a `*const` pointer), is viewed
// as `[const T;]`, which declares no member that mutates: each is R025E
// with the notes a const slice's miss carries. A member that changes the
// length is a vector's, and its R025E says the array has a fixed size. A
// name nothing declares is the plain miss.

class Holder {
    pub var buf: [i32; 3] = [3, 2, 1]

    pub fn Holder(self) { }

    pub fn peek(const self) -> usize {
        self.buf.sort()
        return self.buf.size()
    }
}

fn takes(const a: [i32; 3]) {
    a.fill(0)
}

fn through(p: *const [i32; 3]) {
    p->reverse()
}

fn main() -> i32 {
    const c: [i32; 3] = [3, 1, 2]
    c.sort()
    c.swap(0, 1)
    c.rotate(1)
    c.sort_unstable()
    var *g? = c.get_mut(0)
    var n = c.size()
    var a: [i32; 3] = [1, 2, 3]
    a.push(4)
    a.pop()
    a.clear()
    a.frobnicate()
    return 0
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: fixed_array_members_reject.k:14:18: error [R025E]: no member named 'sort' in a const '[i32; 3]': it is viewed as '[const i32;]', which has none
// CHECK-NEXT: slice.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: 'sort' is a member of the primary declaration, which '[const i32;]' is not an instance of
// CHECK-NEXT: slice.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: '[const i32;]' is an instance of this specialization, which does not declare 'sort'
// CHECK: fixed_array_members_reject.k:20:7: error [R025E]: no member named 'fill' in a const '[i32; 3]': it is viewed as '[const i32;]', which has none
// CHECK: fixed_array_members_reject.k:24:8: error [R025E]: no member named 'reverse' in a const '[i32; 3]': it is viewed as '[const i32;]', which has none
// CHECK: fixed_array_members_reject.k:29:7: error [R025E]: no member named 'sort' in a const '[i32; 3]': it is viewed as '[const i32;]', which has none
// CHECK: fixed_array_members_reject.k:30:7: error [R025E]: no member named 'swap' in a const '[i32; 3]': it is viewed as '[const i32;]', which has none
// CHECK: fixed_array_members_reject.k:31:7: error [R025E]: no member named 'rotate' in a const '[i32; 3]': it is viewed as '[const i32;]', which has none
// CHECK: fixed_array_members_reject.k:32:7: error [R025E]: no member named 'sort_unstable' in a const '[i32; 3]': it is viewed as '[const i32;]', which has none
// CHECK: fixed_array_members_reject.k:33:17: error [R025E]: no member named 'get_mut' in a const '[i32; 3]': it is viewed as '[const i32;]', which has none
// CHECK: fixed_array_members_reject.k:36:7: error [R025E]: no member named 'push' in '[i32; 3]': an array has a fixed size
// CHECK-NEXT: note [I900N]: 'push' is a member of the vector '[i32]', whose length can change; declare a vector to grow or shrink it
// CHECK: fixed_array_members_reject.k:37:7: error [R025E]: no member named 'pop' in '[i32; 3]': an array has a fixed size
// CHECK: fixed_array_members_reject.k:38:7: error [R025E]: no member named 'clear' in '[i32; 3]': an array has a fixed size
// CHECK: fixed_array_members_reject.k:39:7: error [R025E]: no member named 'frobnicate' in '[i32; 3]'
