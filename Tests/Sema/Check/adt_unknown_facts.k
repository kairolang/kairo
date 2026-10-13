// A non-generic ADT gets exactly one form of each special member, picked
// from its payloads' lifecycle facts. A payload that is an instance of a
// generic record reads its pattern's facts, which are not known until
// instantiation, so such an enum cannot be laid out yet: one error at the
// enum, with a note at the payload field that left the facts open. An enum
// over scalars and a non-generic class is laid out and not reported, and so
// is a generic one, whose members clang picks per instance.

class <T> Box { pub var v: T }
class Known { pub var id: i32 }

enum W { Has { b: Box<i32> }, Empty }
// CHECK: adt_unknown_facts.k:[[@LINE-1]]:6: error [SC116E]: an enum whose payload's lifecycle is not known until instantiation is not yet supported
// CHECK: adt_unknown_facts.k:[[@LINE-2]]:16: note [SC116N]: 'b' of variant 'Has' has type 'Box<i32>', whose copy, move and destruction are not known until instantiation

enum Fine { Num { a: i32, b: f64 }, Obj { k: Known }, Nothing }
enum <T> Gen { Has { b: Box<T> }, Empty }

fn main() -> i32 { return 0; }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
