// The contract `fn f() const` ([[gnu::const]]) and `@pure` ([[gnu::pure]])
// make with clang: the call returns a value, returns at all, never
// unwinds, and the function is not virtual. Each function below breaks
// one rule (SC200E); the ones that stand on the declaration itself carry
// a fix-it removing the promise. purity_contract_body.k has the body
// rules.

class Base {
    @pure
    virtual fn v(const self) -> i32 { return 1 }
}

class Acc {
    var n: i32 = 0
    @pure
    fn bump(self) -> i32 { self.n = 1; return self.n }
}

fn never() -> ! { crash!() }

fn no_result(x: i32) const { }
@pure
fn no_result_pure(x: i32) { }
fn diverges() const -> ! { never() }
@unwind
fn unwinds(x: i32) const -> i32 { return x }
@pure
fn writes_inout(@inout x: i32) -> i32 { x = 2; return x }
fn reads_inout(@inout x: i32) const -> i32 { return x }

// Clean - a by-value record's own field, a tuple of scalars, a hint
// intrinsic, an eval constant, a const callee, a pointer read in @pure.
class Big {
    var a: i32 = 1
    var s: string = "x"
}
eval K: i32 = 3
fn field_of(b: Big) const -> i32 { return b.a + K }
fn take_i(x: i32) const -> i32 { return x * 2 }
fn pair(x: i32) const -> (i32, i32) { return (x, take_i(x)) }
fn hinted(x: i32) const -> bool { return __builtin_expect(x > 0, true) }
@pure
fn reads_ptr(p: unsafe *i32) -> i32 { unsafe { return *p } }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=CLEAN
// CHECK-DAG: purity_contract.k:9:5: error [SC200E]: 'v' is @pure but is virtual or an interface requirement
// CHECK-DAG: fix-it:"{{.*}}purity_contract.k":{9:5-9:10}:""
// CHECK-DAG: purity_contract.k:16:28: error [SC200E]: 'bump' is @pure, so it cannot assign to a field of 'self'
// CHECK-DAG: purity_contract.k:21:22: error [SC200E]: 'no_result' is const but returns no value
// CHECK-DAG: fix-it:"{{.*}}purity_contract.k":{21:22-21:27}:""
// CHECK-DAG: purity_contract.k:22:1: error [SC200E]: 'no_result_pure' is @pure but returns no value
// CHECK-DAG: fix-it:"{{.*}}purity_contract.k":{22:1-22:6}:""
// CHECK-DAG: purity_contract.k:24:15: error [SC200E]: 'diverges' is const but never returns
// CHECK-DAG: fix-it:"{{.*}}purity_contract.k":{24:15-24:20}:""
// CHECK-DAG: purity_contract.k:26:20: error [SC200E]: 'unwinds' is const but is marked '@unwind'
// CHECK-DAG: purity_contract.k:28:41: error [SC200E]: 'writes_inout' is @pure, so it cannot assign to a parameter passed by reference
// CHECK-DAG: purity_contract.k:29:53: error [SC200E]: 'reads_inout' is const, so it cannot read 'x', which is passed by reference
// CLEAN-NOT: purity_contract.k:{{3[5-9]|4[0-4]}}:{{[0-9]+}}: error
