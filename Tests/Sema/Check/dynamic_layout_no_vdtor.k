// `__builtin_dynamic_size<T>` / `_align<T>` at a T that is polymorphic but
// has no virtual destructor: what a `*T` points at may be a larger derived
// class, and only a virtual destructor gives T the hidden `__kairo_layout()`
// that says which. An error at the use, through a generic caller (as
// `destroy<T>` reaches it) with the instantiation note.

class NoVd {
    var a: i64
    fn NoVd(self) { self.a = 1 }
    virtual fn f(self) -> i32 { return 1 }
}

class Fine {
    var a: i64
    fn Fine(self) { self.a = 1 }
}

fn <T> sized_free(p: *T) -> usize {
    return __builtin_dynamic_size<T>(p)
}

fn main() -> i32 {
    var n = NoVd()
    var direct = __builtin_dynamic_align<NoVd>(&n)
    var f = Fine()
    var ok = sized_free<Fine>(&f)
    return sized_free<NoVd>(&n) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      dynamic_layout_no_vdtor.k:24:{{[0-9]+}}: error [SC159E]: '__builtin_dynamic_align<NoVd>' needs the layout of what a '*NoVd' points at, but 'NoVd' is polymorphic and has no virtual destructor
// DIAG-NEXT: dynamic_layout_no_vdtor.k:7:{{[0-9]+}}: note [SC159N]: declare 'virtual fn op delete(self)' in 'NoVd'
// DIAG:      dynamic_layout_no_vdtor.k:27:{{[0-9]+}}: error [SC159E]: '__builtin_dynamic_size<NoVd>' needs the layout
// DIAG:      dynamic_layout_no_vdtor.k:19:{{[0-9]+}}: note [I900N]: in instantiation of
// DIAG-NOT:  {{error|warning}} [
