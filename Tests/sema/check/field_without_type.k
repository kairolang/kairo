// A field declares its type (variables.mdx: "Fields declare their type and
// never take a shorthand"), so `var a = 5` in a record body is an error at
// the field, reported by Kairo -- not an internal error in codegen.
//
// It is not left to type-check and fail in a build ("InterfaceEmitter:
// initializer of an eval or array-typed field reached codegen;
// FeatureGateCheck rejects it"): the parser refuses it as it refuses the
// field shorthands (S058E). Inferring the type like a
// VariableDecl would contradict variables.mdx; if the docs change instead,
// turn this into a run test.
//
//

struct S {
    var a = 5
// CHECK: field_without_type.k:[[@LINE-1]]:9: error [S058E]: a field declares its type; write 'a: T'
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
