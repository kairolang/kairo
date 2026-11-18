// The rules that stay in force inside generic bodies while their valid
// shapes compile: the intrinsics keep their parameter types
// (`__builtin_mul_overflow` takes a pointer result, `__builtin_construct_at`
// a byte pointer), a bound is checked at the instantiation (SC162E) even when
// the body only dereferences a pointer to the parameter, and a `const` match
// binder on a pointer payload is const (SC071E).

class <T> C {
    fn m(self, a: T, b: T) -> bool {
        var r: T = 0
        return __builtin_mul_overflow<T>(a, b, r)
    }
}

fn <T> mk(buf: u64) -> T {
    var p = __builtin_construct_at<T>(buf, 42)
    return *p
}

interface Eqx { fn op == (const self, const o: Self) -> bool }
class Plain { pub var v: i32 = 0 }
fn <T impl Eqx> same(const x: T, p: *T) -> bool { return *p == x }

enum Expr {
    Num { v: i64 },
    Add { l: *Expr, r: *Expr },
}

fn value(e: *Expr) -> i64 {
    match *e {
        case .Num(const v) { return v }
        case .Add(const l, const r) {
            l = r
            return 0
        }
    }
}

fn main() -> i32 {
    var c = C<u64>()
    var a = Plain()
    var b = Plain()
    if same(a, &b) { return 1 }
    if c.m(1, 2) { return 1 }
    return mk<i32>(0)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: generic_body_rejections.k:11:16: error [SC063E]: no matching overload for call to '__builtin_mul_overflow'
// CHECK: generic_body_rejections.k:16:13: error [SC063E]: no matching overload for call to '__builtin_construct_at'
// CHECK: generic_body_rejections.k:33:13: error [SC071E]: cannot assign to 'l': it is const
// CHECK: generic_body_rejections.k:43:8: error [SC162E]: 'Plain' does not conform to 'Eqx'
