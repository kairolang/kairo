class Base { var n: i32; }
enum Mode { Read, Write }
enum Text { Some { s: string }, None }
enum Num { One { n: i32 }, Two { p: *i32 } }
enum <T> Opt { Some { v: T }, None }
class HasText derives Base { var t: Text; }     // expect: error -- a string payload makes the enum non-trivially destroyed
class HasMode derives Base { var m: Mode; }     // expect: clean -- a plain enum is an integer
class HasNum derives Base { var p: Num; }       // expect: clean -- builtin and pointer payloads are trivial
class HasOpt derives Base { var o: Opt<i32>; }  // expect: clean -- a dependent payload is unknown, and unknown is not diagnosed

// --- lit wiring -----------------------------------------------------------
// ClassLifecycle's facts for an enum, observed through the one rule that
// reads a field's destructor triviality: the virtual-destructor rule. Each
// class adds nothing but one enum field, so the class has destruction work of
// its own exactly when that enum's destructor is non-trivial.
//
// An ADT follows the struct rule over its payload fields, so `Text` (a
// `string` payload) is non-trivial and `Num` (i32, a pointer) is not. `Opt`'s
// payload is `T`: the instance reads its pattern, where the payload is
// unknown, and the rule skips an unknown fact rather than guess. Once facts
// are computed per instance, `Opt<i32>` is trivial and `HasOpt` stays clean
// for that reason instead.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// DIAG:     adt_lifecycle_dtor.k:6:{{[0-9]+}}: error [SC056E]: class 'HasText' has a non-trivial destructor, but its base 'Base' does not have a virtual destructor
// DIAG-NOT: {{error|warning}} [
