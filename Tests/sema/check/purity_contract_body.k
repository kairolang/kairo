// What the body of a const / @pure function may not do, beyond the old
// rules (const_fn_errors.k): own memory (a string local, result, literal,
// f-string, a by-value copy), read a parameter passed by reference in a
// const fn (memory(none) lets clang move the call across a store
// to it), stop the program (assert, unwrap!, a trap), or call what it
// cannot see (a function value, a user operator that made no promise, a
// parameter's default, a container for-in). One SC200E each; `sums` is clean.

class Big {
    var a: i32 = 1
    var s: string = "x"
}

struct V2 {
    var x: i32
    fn op + (const self, o: V2) -> V2 { return V2 { x: self.x + o.x } }
}

fn take(b: Big) const -> i32 { return b.a }
fn dflt(x: i32, y: i32 = 4) const -> i32 { return x + y }

fn local_string(x: i32) const -> i32 { var s: string; return x }
fn string_result(x: i32) const -> string { return "abc" }
fn formats(x: i32) const -> bool { return f"{x}" == "" }
fn copies(b: Big) const -> i32 { return take(b) }
fn reads_const_ref(const b: Big) const -> i32 { return b.a }
fn asserts(x: i32) const -> i32 { assert x > 0; return x }
fn unwraps(p: i32?) const -> i32 { return unwrap!(p) }
fn calls_value(f: fn (i32) -> i32) const -> i32 { return f(1) }
fn adds(a: V2, b: V2) const -> i32 { return (a + b).x }
fn traps(x: i32) const -> i32 { __builtin_trap(); return x }
fn defaults(x: i32) const -> i32 { return dflt(x) }
fn loops(v: [i32]) const -> i32 { var t = 0; for x in v { t += x }; return t }
fn sums(n: i32) const -> i32 { var t = 0; for i in 0..n { t += i }; return t }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: purity_contract_body.k:22:44: error [SC200E]: 'local_string' is const, so it cannot hold 's', a 'string'
// CHECK-DAG: purity_contract_body.k:23:35: error [SC200E]: 'string_result' is const, so it cannot return a 'string'
// CHECK-DAG: purity_contract_body.k:23:51: error [SC200E]: 'string_result' is const, so it cannot make a 'string'
// CHECK-DAG: purity_contract_body.k:24:44: error [SC200E]: 'formats' is const, so it cannot format a string
// CHECK-DAG: purity_contract_body.k:25:46: error [SC200E]: 'copies' is const, so it cannot copy a 'Big' into a parameter
// CHECK-DAG: purity_contract_body.k:26:56: error [SC200E]: 'reads_const_ref' is const, so it cannot read 'b', which is passed by reference
// CHECK-DAG: purity_contract_body.k:27:35: error [SC200E]: 'asserts' is const, so it cannot assert
// CHECK-DAG: purity_contract_body.k:28:43: error [SC200E]: 'unwraps' is const, so it cannot unwrap with '!'
// CHECK-DAG: purity_contract_body.k:29:58: error [SC200E]: 'calls_value' is const, so it cannot call a function value
// CHECK-DAG: purity_contract_body.k:30:46: error [SC200E]: 'adds' is const, so it cannot call 'op +'
// CHECK-DAG: purity_contract_body.k:31:33: error [SC200E]: 'traps' is const, so it cannot call '__builtin_trap'
// CHECK-DAG: purity_contract_body.k:32:43: error [SC200E]: 'defaults' is const, so it cannot use the default of parameter 'y'
// CHECK-DAG: purity_contract_body.k:33:46: error [SC200E]: 'loops' is const, so it cannot loop with 'for ... in' over this value
// CHECK-NOT: purity_contract_body.k:34:{{[0-9]+}}: error
