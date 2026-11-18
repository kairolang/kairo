// `return t` of a `const` parameter whose type has a move constructor and no
// copy constructor needs a copy out of a place that cannot be moved from:
// SC182E at the return, as for `var u = t` of the same parameter
// (copy_and_move_errors.k; ownership.mdx, final section: "copying out of a
// const place is SC182E"). The compiler accepts the return and clang then
// rejects the generated C++ with CL001E.

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) { self.id = id }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

fn const_param_returned(const t: Tok) -> Tok {
    return t //! SC182E
}

// XFAIL: *

// XFAIL: *
// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: bug_return_const_param.k:15:{{[0-9]+}}: error [SC182E]:
