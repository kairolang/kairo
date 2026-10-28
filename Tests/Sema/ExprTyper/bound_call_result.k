// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// The result of a call through a bound is the requirement's declared return
// type at the BOUND's arguments (MONO.md D0: the body is checked once, against
// its bounds). `c.shine()` through `C impl Fancy<i32>` is an i32, so it is an
// ordinary value from there on: a member of it binds (`c.wrap().w`), a call
// on it chains, and it is checked where it lands (bound_call_result_err.k).
// Before, the interface's parameter stayed unbound, the result typed as
// unknown, and `c.wrap().w` reached codegen with `.w` unbound.

pub struct Q { pub var q: i32 }
pub struct <W> Wrap { pub var w: W }
pub struct <A, B> Two { pub var a: A  pub var b: B }

pub interface <T> Fancy {
    fn shine(const self) -> T
    fn wrap(const self) -> Wrap<T>
    fn me(const self) -> Self
    fn <U> map(const self, u: U) -> U
    fn <U> pair(const self, u: U) -> Two<T, U>
}
// `get` is declared on Container and reached through Wrapped's `derives`, at
// Container<Wrap<V>>: the declaring instance, not the bound itself.
pub interface <E> Container { fn get(const self, i: i32) -> E }
pub interface <V> Wrapped derives Container<Wrap<V>> { fn raw(const self) -> V }
pub interface Plain { fn me(const self) -> Self  fn n(const self) -> i32 }

pub fn <C impl Fancy<i32>> concrete(c: C) -> i32 {
    var a = c.shine()
    var b = c.wrap().w
    var d = c.me().shine()
    var e = c.map(true)
    var f = c.pair(2.5).b
    var g = c.pair(Q { q: 1 }).b.q
    return a + b + d + g
}
// The dump of this file, past its bindings section, which names the
// functions too.
// SEMA:       ===== SEMA fid {{.*}}bound_call_result.k =====
// SEMA:       -- expression types --
// SEMA:       <tu>::concrete
// SEMA:       CallExpr {{.*}} : i32  [arg_map self]
// SEMA:       ChainExpr {{.*}} : i32
// SEMA-NEXT:  CallExpr {{.*}} : Wrap<i32>  [arg_map self]
// SEMA:       CallExpr {{.*}} : i32  [arg_map self]
// SEMA:       CallExpr {{.*}} : C  [arg_map self]
// SEMA:       CallExpr {{.*}} : bool  [arg_map self 0]
// SEMA:       ChainExpr {{.*}} : f64
// SEMA-NEXT:  CallExpr {{.*}} : Two<i32, f64>  [arg_map self 0]
// SEMA:       ChainExpr {{.*}} : i32
// SEMA-NEXT:  CallExpr {{.*}} : Two<i32, Q>  [arg_map self 0]

pub fn <C impl Wrapped<i32>> inherited(c: C) -> i32 { return c.get(1).w + c.raw() }
// SEMA:       <tu>::inherited
// SEMA:       ChainExpr {{.*}} : i32
// SEMA-NEXT:  CallExpr {{.*}} : Wrap<i32>  [arg_map self 0]
// SEMA:       CallExpr {{.*}} : i32  [arg_map self]

// A bound over the body's own parameter: the result is that parameter.
pub fn <E, C impl Fancy<E>> dependent(c: C, z: E) -> E {
    var w: Wrap<E> = c.wrap()
    var s: E = c.shine()
    return w.w
}
// SEMA:       <tu>::dependent
// SEMA:       CallExpr {{.*}} : Wrap<E>  [arg_map self]
// SEMA:       CallExpr {{.*}} : E  [arg_map self]

// A non-generic interface: `Self` is the parameter, as before.
pub fn <P impl Plain> plain(p: P) -> i32 { return p.me().n() }
// SEMA:       <tu>::plain
// SEMA:       CallExpr {{.*}} : i32  [arg_map self]
// SEMA-NEXT:  ChainExpr
// SEMA-NEXT:  CallExpr {{.*}} : P  [arg_map self]

fn main() -> i32 { return 0 }

// DIAG-NOT: {{error|warning}}
