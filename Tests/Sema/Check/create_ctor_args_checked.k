// `@create T(args)` / `create<T>(args)` forwards the arguments to
// `T(args...)` inside alloc.k's generic body, which only C++ instantiates,
// so a raw pointer reached a safe `*i32` constructor parameter with no
// Kairo diagnostic. The arguments resolve against T's constructors as
// a direct `T(args)` does. Copying through `@create T(other)` (the implicit
// transfer constructor) and a well-typed argument stay accepted.
class Node {
    var v: i32
    fn Node(self, p: *i32) { self.v = *p }
}

fn bad() {
    var x: i32 = 3
    var unsafe *raw = unsafe &x
    var n = @create Node(raw)
}

fn good() {
    var x: i32 = 3
    var *a = @create Node(&x)
    var *b = @create Node(*a)
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: create_ctor_args_checked.k:15:13: error [SC063E]: no matching overload for call to 'Node'
// CHECK: note [I900N]: candidate not viable: cannot convert argument of type 'unsafe *i32' to parameter 'p' of type '*i32'
