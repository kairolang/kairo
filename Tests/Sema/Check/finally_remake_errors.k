// Re-construction after `x.finally()` is a whole assignment of a new value
// (Compiler/Spec/Lowering.md#union-storage-locals). Still errors: a use
// before it (SC303E), a write to a part of the ended local (SC303E: it is
// no construction), a use where only one path re-constructed (SC303E),
// and two `finally()` with no re-construction between (SC304E), which a
// generic body is checked for as any other.
class Res {
    @copy fn Res(self, const other: Self) = default
    var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    fn op finally(self) { }
}

interface Tagged { fn tag(const self) -> i32 }

fn use_before() -> i32 {
    var r = Res(1)
    r.finally()
    var n = r.id
    r = Res(2)
    return n
}

fn part_write() {
    var r = Res(1)
    r.finally()
    r.id = 3
}

fn one_path(c: bool) -> i32 {
    var r = Res(1)
    r.finally()
    if c { r = Res(2) }
    return r.id
}

fn <T impl Tagged> twice(x: T) {
    var y = x
    y.finally()
    y.finally()
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: finally_remake_errors.k:19:13: error [SC303E]: use of finalized value 'r'
// CHECK: finally_remake_errors.k:18:5: note [SC303N]: 'r' was finalized here; its destructor has run
// CHECK: finally_remake_errors.k:27:5: error [SC303E]: use of finalized value 'r'
// CHECK: finally_remake_errors.k:34:12: error [SC303E]: use of finalized value 'r'
// CHECK: finally_remake_errors.k:40:5: error [SC304E]: 'y' already finalized
