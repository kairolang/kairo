// Access control is Kairo's (classes.mdx, Visibility): a `priv` member --
// a field or `static` by default, a method or constructor marked `priv` --
// is not accessible from another module, and Kairo reports it, so
// `--type-check-only` does. Inputs/access_other_module/main.k reads acc.k's
// private field (line 5) and private static (line 6), calls its `priv`
// method (line 7) and its `priv` constructor (line 8).
//
// XFAIL: *
// Ticket "[Sema] Access control is checked only by clang: private members
// and `priv` constructors" (private/IMPORTANT/TICKETS.TXT, 2026-10-26;
// GitHub #93; status.mdx, Checked by C++, Not by Kairo). Today
// --type-check-only accepts all four; only a full build reports them, as
// clang CL001E ("'secret' is a private member of 'acc::Acc'", "calling a
// private constructor of class 'acc::Acc'"). The code is not decided; the
// checks ask for an error at each line. When it XPASSes,
// delete the XFAIL and pin the code and message.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/access_other_module && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: main.k:5:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
// CHECK: main.k:6:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
// CHECK: main.k:7:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
// CHECK: main.k:8:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
