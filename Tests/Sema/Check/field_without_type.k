// A field declares its type (variables.mdx: "Fields declare their type and
// never take a shorthand"), so `var a = 5` in a record body is an error at
// the field, reported by Kairo -- not an internal error in codegen.
//
// XFAIL: *
// Ticket "[Sema/Codegen] A field with an initializer and no type
// type-checks, then ICEs in InterfaceEmitter" (private/IMPORTANT/
// TICKETS.TXT, 2026-10-26). Today --type-check-only accepts it, and a
// build ICEs: "InterfaceEmitter: initializer of an eval or array-typed
// field reached codegen; FeatureGateCheck rejects it". (The ticket's other
// option, inferring the type like a VariableDecl, would contradict
// variables.mdx; if the docs change instead, turn this into a run test.)
// The code is not decided; the check asks for an error at the field. When
// it XPASSes, delete the XFAIL and pin the code and message.

struct S {
    var a = 5
// CHECK: field_without_type.k:[[@LINE-1]]:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
