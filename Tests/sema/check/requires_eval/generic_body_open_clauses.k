// A generic body is checked once against its bounds (generics.mdx), so a
// call there whose overloads are told apart only by `requires` clauses that
// test an unbounded type parameter is an error at the definition (SC320E),
// not a choice left to each instance. Each note names a candidate and the
// bound that selects it, or says that none can: a negated conformance or a
// value predicate is never promised by a bound. std::copy is bounded by
// Copyable, so calling it on an unbounded parameter is an error at the
// definition too.

import std

interface Loud {
    fn shout(const self) -> i32
}

fn <T> say(const x: T) -> i32 requires T impl Loud {
    return x.shout()
}

fn <T> say(const x: T) -> i32 requires !(T impl Loud) {
    return 0
}

fn <T> width(const x: T) -> i32 requires sizeof T <= 4 {
    return 1
}

fn <T> width(const x: T) -> i32 requires sizeof T > 4 {
    return 2
}

fn <T> relay(const x: T) -> i32 {
    return say(x)
}

fn <T> measure(const x: T) -> i32 {
    return width(x)
}

fn <T> dup(const x: T) -> T {
    return std::copy(x)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: generic_body_open_clauses.k:33:12: error [SC320E]: call to 'say' cannot be resolved in this generic body: its candidates' 'requires' clauses test a type parameter whose bounds do not decide them
// CHECK-NEXT: generic_body_open_clauses.k:16:1: note [SC320N]: this candidate is selected when 'T' implements 'Loud': add the bound 'T impl Loud'
// CHECK-NEXT: generic_body_open_clauses.k:20:1: note [SC320N]: no bound selects this candidate: it applies when 'T' does not implement 'Loud', and no bound can promise that 'T' does not implement 'Loud'
// CHECK-NEXT: generic_body_open_clauses.k:33:12: note [I900N]: a generic body is checked against its bounds, not per instance, so the bounds must decide every candidate's clause
// CHECK: generic_body_open_clauses.k:37:12: error [SC320E]: call to 'width'
// CHECK-NEXT: generic_body_open_clauses.k:24:1: note [SC320N]: no bound selects this candidate: its clause tests the parameter with a condition no bound can promise
// CHECK-NEXT: generic_body_open_clauses.k:28:1: note [SC320N]: no bound selects this candidate: its clause tests the parameter with a condition no bound can promise
// std::copy takes `T impl Copyable`: an unbounded T is refused at the call.
// CHECK: generic_body_open_clauses.k:41:12: error
//
// CHECK-NOT: error [SC064E]

// A constrained overload beside an unconstrained one: constraints order
// only candidates whose clauses are decided, so with 'T' unbounded the
// choice is still the instance's, and an error here.
interface Quiet {
    fn hush(const self) -> i32
}

fn <T> pick(const x: T) -> i32 requires T impl Quiet {
    return 1
}

fn <T> pick(const x: T) -> i32 {
    return 2
}

fn <T> forward(const x: T) -> i32 {
    return pick(x)
}

// CHECK2: generic_body_open_clauses.k:74:12: error [SC320E]: call to 'pick'
// CHECK2-NEXT: generic_body_open_clauses.k:65:1: note [SC320N]: this candidate is selected when 'T' implements 'Quiet': add the bound 'T impl Quiet'
// CHECK2-NEXT: generic_body_open_clauses.k:69:1: note [SC320N]: this candidate's clause does not test the parameter; it is chosen only where the others' clauses are known false, which no bound can promise
// CHECK2-NOT: error
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=CHECK2
