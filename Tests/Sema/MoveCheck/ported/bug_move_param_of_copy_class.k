// `@move` on a parameter whose class is copy-only (a `@copy` constructor and
// no move constructor) is a compile error (functions-parameter-modes.mdx,
// `@move` is checked: "Copy-only class: `@move` is a compile error"). The
// compiler accepts the declaration and the call. The generic form
// `fn <T> f(@move x: T)` is allowed for every T and is not part of this case.

class Cp {
    pub var id: i32 = 0
    fn Cp(self, id: i32) { self.id = id }
    @copy fn Cp(self, const other: Self) { self.id = other.id }
}

fn take_cp(@move c: Cp) -> i32 { return c.id }

fn caller() -> i32 {
    var c = Cp(1)
    return take_cp(c)
}

// --- lit wiring -----------------------------------------------------------
// XFAIL: *
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: bug_move_param_of_copy_class.k:13:{{[0-9]+}}: error [{{[A-Z]+[0-9]+E}}]:
