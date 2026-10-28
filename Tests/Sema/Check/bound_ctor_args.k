// `T(args)` in a bounded body constructs a T through a constructor
// requirement of one of T's bounds (interfaces-requirements.mdx, Constructor
// Requirements), so its arguments are checked against that requirement's
// parameters, with Self as T, like any call: a `string` is not an `i32`.
//
// XFAIL: *
// Ticket "[Sema] `T(args)` in a bounded body is not checked against the
// bound's constructor requirement" (private/IMPORTANT/TICKETS.TXT,
// 2026-10-24). Today CallTyping::_param_ctor_call matches the ARITY only,
// so `T("seven")` type-checks and clang decides it per instance. The error
// code is not decided; the check below asks for an error at the call. When
// it XPASSes, delete the XFAIL and pin the code and message.

interface Sized {
    fn Sized(self, n: i32)
}

fn <T impl Sized> good() -> T {
    return T(7)
}

fn <T impl Sized> bad() -> T {
    return T("seven")
// CHECK: bound_ctor_args.k:[[@LINE-1]]:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
