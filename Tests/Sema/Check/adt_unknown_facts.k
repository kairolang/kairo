// A non-generic ADT gets exactly one form of each special member, picked
// from its payloads' lifecycle facts. A payload that is an instance of a
// generic record has facts of its own -- its pattern's fields over its
// arguments (ClassLifecycle, Instances; MONO.md G6) -- so `Box<i32>` is as
// known as `Known` and nothing here is reported: not the enum over the
// instance, not the one over scalars and a non-generic class, not the generic
// one, whose members clang picks per instance. (Before G6 the first was
// SC116E, "not known until instantiation": an instance read its pattern.)

class <T> Box { pub var v: T }
class Known { pub var id: i32 }

enum W { Has { b: Box<i32> }, Empty }

enum Fine { Num { a: i32, b: f64 }, Obj { k: Known }, Nothing }
enum <T> Gen { Has { b: Box<T> }, Empty }

fn main() -> i32 { return 0; }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: {{error|warning}}
