// partial_spec_requires.k -- exit 0
// Partial specializations selected by `requires` (MONO.md G12), compiled
// and run. The registry selects a partial whose pattern matches and whose
// clause holds at the instance's arguments; the more specialized pattern
// wins first (`<P> Store<*P>` over `<P> Store<P>`), the clause after. C++
// selects too, from the same clauses written on the emitted partials, and
// each instance pins Kairo's pick: every body of a template with such a
// partial carries `__kairo_spec` (0 the primary, 1 + its index a partial),
// asserted beside the instance's explicit instantiation.
//   Store<i8>   : sizeof i8 <= 4            -> `<P> Store<P>`   (1)
//   Store<i64>  : neither clause holds      -> the primary      (0)
//   Store<*i64> : sizeof i64 >= 8           -> `<P> Store<*P>`  (2)
//   Store<*i8>  : sizeof i8 < 8, *i8 > 4    -> the primary      (0)
pub struct <T> Store { pub var value: T }
pub struct <P> Store<P> requires sizeof P <= 4 { pub var small: P }
pub struct <P> Store<*P> requires sizeof P >= 8 { pub var wide: *P }
fn main() -> i32 {
    var a = Store<i8> { small: 1 }
    var b = Store<i64> { value: 2 }
    var x: i64 = 5
    var c = Store<*i64> { wide: &x }
    var y: i8 = 1
    var d = Store<*i8> { value: &y }
    var r = 0
    if a.small != 1 { r += 1 }
    if b.value != 2 { r += 2 }
    if *c.wide != 5 { r += 4 }
    if *d.value != 1 { r += 8 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<class P> requires(((sizeof(P)) <=(4))) struct Store<P> {
// CXX-NEXT: static constexpr unsigned __kairo_spec = 1u;
// CXX: template<class P> requires(((sizeof(P)) >=(8))) struct Store<P *> {
// CXX-NEXT: static constexpr unsigned __kairo_spec = 2u;
// CXX: static_assert({{ ?}}::{{.*}}Store<signed char>::__kairo_spec == 1u,
// CXX: static_assert({{ ?}}::{{.*}}Store<signed long>::__kairo_spec == 0u,
// CXX: static_assert({{ ?}}::{{.*}}Store<signed long *>::__kairo_spec == 2u,
// CXX: static_assert({{ ?}}::{{.*}}Store<signed char *>::__kairo_spec == 0u,

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
