// The part of a branch, loop or short-circuit that runs whenever the
// construct does is a definite read: an `if` or `while` condition, a `match`
// scrutinee, the iterable of a `for`, the init of a C-style `for`, the
// condition of an `if` expression, the left side of `&&` and `||`. A
// function that reads a script variable there, called before the variable's
// line, is a compile error. The part that may not run is left to the
// runtime guard: a right operand, a branch, a loop body, a match arm.

import std::io::println

fn load() -> i32 { return 3 }
fn in_if() { if late > 0 { println("a") } }
fn in_while() { while late > 100 { println("b") } }
fn in_match() { match late { case 1 { println("c") } default { } } }
fn in_and(b: bool) -> bool { return late > 0 && b }
fn in_or(b: bool) -> bool { return late > 0 || b }
fn in_for() { for i in 0..late { println("d") } }
fn in_ifexpr() -> i32 { return if late > 0 => 1 else => 2 }
fn in_cfor() { for var i = late; i < 10; ++i { println("e") } }

fn rhs_and(b: bool) -> bool { return b && late > 0 }
fn in_then(b: bool) { if b { println(f"{late}") } }
fn in_body(b: bool) { while b { println(f"{late}") } }
fn in_arm(n: i32) { match n { case 1 { println(f"{late}") } default { } } }

in_if()
in_while()
in_match()
in_and(true)
in_or(true)
in_for()
in_ifexpr()
in_cfor()
rhs_and(false)
in_then(false)
in_body(false)
in_arm(0)
var late = load()

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// DIAG: read_before_init_lead.k:26:1: error [SC236E]: 'in_if' reads script variable 'late' before the line that gives it a value has run
// DIAG: read_before_init_lead.k:27:1: error [SC236E]: 'in_while' reads script variable 'late' before the line that gives it a value has run
// DIAG: read_before_init_lead.k:28:1: error [SC236E]: 'in_match' reads script variable 'late' before the line that gives it a value has run
// DIAG: read_before_init_lead.k:29:1: error [SC236E]: 'in_and' reads script variable 'late' before the line that gives it a value has run
// DIAG: read_before_init_lead.k:30:1: error [SC236E]: 'in_or' reads script variable 'late' before the line that gives it a value has run
// DIAG: read_before_init_lead.k:31:1: error [SC236E]: 'in_for' reads script variable 'late' before the line that gives it a value has run
// DIAG: read_before_init_lead.k:32:1: error [SC236E]: 'in_ifexpr' reads script variable 'late' before the line that gives it a value has run
// DIAG: read_before_init_lead.k:33:1: error [SC236E]: 'in_cfor' reads script variable 'late' before the line that gives it a value has run
