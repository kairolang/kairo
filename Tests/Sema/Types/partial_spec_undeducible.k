// A partial specialization whose pattern never names one of its own
// parameters can never be selected: `U` below cannot be deduced from any
// argument list. C++ rejects such a partial at its declaration ("not
// deducible"), and Kairo's generics follow C++ here (OVERLOAD.md: the
// behaviour is 1:1), so it is an error at the declaration -- not a
// specialization that silently never applies.
//
// XFAIL: *
// Ticket "[Sema] A partial specialization whose pattern never names one of
// its parameters is silently inert" (private/IMPORTANT/TICKETS.TXT,
// 2026-10-25). Today it is accepted without a word and every instance takes
// the primary (InstantiationRegistry::_matches never selects it). Passes
// once TypeResolve::_register_type_spec reports it. The code is not decided;
// the check asks for an error at the declaration. When it XPASSes, delete
// the XFAIL and pin the code and message.

pub class <T> Store {
    pub fn kind(const self) -> i32 = 0
}

pub class <P, U> Store<*P> {
// CHECK: partial_spec_undeducible.k:[[@LINE-1]]:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
    pub fn kind(const self) -> i32 = 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
