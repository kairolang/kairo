// A generic record whose declared `@copy` constructor its instance
// loses to that constructor's `requires` -- `[Mv]`, whose copy needs Mv's --
// read as COPY (ClassLifecycle reads the declaration), so copying one was
// caught only by clang (CL001E "no matching constructor"). It is SC182E at
// the copy: the vector is a copy type, so `var b = a` copies it, the
// copy needs each element's, and with one transfer constructor (`@copy`)
// there is no move to fall back on. Reported at every copying transfer,
// assignment included, and through a nested `[[Mv]]`; a `const` parameter
// takes no copy, and a vector of a copyable element is untouched.

class Mv {
    var v: i32
    fn Mv(self, v: i32) { self.v = v }
    @move fn Mv(self, other: Self) = default
}

fn take(v: [Mv]) -> usize { return v.size() }
fn peek(const v: [Mv]) -> usize { return v.size() }

fn make() -> [Mv] {
    var a: [Mv]
    return a
}

fn main() -> i32 {
    var a: [Mv]
    a.emplace_back(1)
    var b = a
    var w: [Mv]
    w = a
    var n = take(a)
    var m = peek(a)
    var aa: [[Mv]]
    var bb = aa
    var ints: [i32]
    var ints2 = ints
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: copy_constrained_container.k:22:12: error [SC182E]: cannot copy a value of type '[Mv]': copying it copies each 'Mv', and 'Mv' cannot be copied
// CHECK-NEXT: copy_constrained_container.k:22:12: note [I900N]: '[Mv]' is a copy type, so the transfer out of the function copies it, and it has no move to fall back on (its one transfer constructor is '@copy'): take it as a 'const' parameter or through a pointer, or build it in place
// CHECK-NEXT: vector.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: the copy constructor is constrained here
// CHECK: copy_constrained_container.k:28:13: error [SC182E]: cannot copy a value of type '[Mv]'
// CHECK-NEXT: note [I900N]: '[Mv]' is a copy type, so the transfer into 'b' copies it
// CHECK: copy_constrained_container.k:30:9: error [SC182E]: cannot copy a value of type '[Mv]'
// CHECK: copy_constrained_container.k:31:18: error [SC182E]: cannot copy a value of type '[Mv]'
// CHECK: copy_constrained_container.k:34:14: error [SC182E]: cannot copy a value of type '{{\[\[}}Mv{{\]\]}}': copying it copies each '[Mv]', and '[Mv]' cannot be copied
// CHECK-NOT: error
