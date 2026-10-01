// generic_pattern_err.k -- SC063E at the call, note: "the receiver is not an instance this extension applies to"
struct <T> Box  { var v: T; }
struct <T> Wrap { var inner: T; }

extend <T> Wrap<Box<T>> {
    fn unbox(const self) -> T { return self.inner.v; }
}

fn main() -> i32 {
    var w = Wrap<i32> { inner: 9 };
    return w.unbox();
}

// --- lit wiring -----------------------------------------------------------
// XFAIL: *
// Waiting on the same ChainBinding gap as generic_pattern.k: the body's
// `self.inner.v` is R051E before the call is ever judged. Once that lands,
// the receiver `Wrap<i32>` does not unify with `Wrap<Box<T>>`, so the call
// has no viable candidate (bind_from_extension).
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: R051E
// CHECK: generic_pattern_err.k:11:{{[0-9]+}}: error [SC063E]:
// CHECK: the receiver is not an instance this extension applies to
