// A specialization whose signature two primaries share, the two told apart
// only by their `requires` clauses, is not paired: Kairo does not order
// primaries by their clauses when it pairs a specialization, so this is
// "more than one primary" (SC330E) rather than a guess.

interface Loud { fn shout(const self) -> i32 }
class Cat { }

fn <T> say(const x: T) -> i32 requires T impl Loud { return x.shout() }
fn <T> say(const x: T) -> i32 requires !(T impl Loud) { return 0 }
fn <> say<Cat>(const x: Cat) -> i32 { return 9 }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: fn_spec_constrained_primaries.k:11:1: error [SC330E]: explicit specialization of 'say' matches more than one primary template
// CHECK: note [SC330N]: primary template is here
// CHECK: note [SC330N]: primary template is here
// CHECK-NOT: error
