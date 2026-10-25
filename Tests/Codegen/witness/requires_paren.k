// witness/requires_paren.k -- exit 62
// A bounded generic whose return type starts with `::`. The head's clause
// was spelled `requires ::m::Scalable_c<T> ::builtin::Tuple2<...> f(...)`,
// and C++ reads that `::` as continuing the concept's qualified name: clang
// rejected the head ("qualified name refers into a specialization of
// function template"), then every call and the explicit instantiation. The
// clause is parenthesized now. A tuple return, a record return, and a
// two-bound conjunction, each through a function pointer and a
// destructuring bind (the shape of the program that found it).
pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub interface Bumpable {
    fn bump(const self) -> i32
}
pub struct Metric {
    pub var base: i32
}
extend Metric {
    pub fn scale(const self, factor: i32) -> i32 = self.base * factor
    pub fn bump(const self) -> i32 = self.base + 1
}
pub struct Pair {
    pub var lo: i32
    pub var hi: i32
}

fn add(val: i32, bonus: i32) -> i32 = val + bonus

pub fn <T impl Scalable> tuple_of(a: T, b: T, bonus: i32, op_fn: fn(i32, i32) -> i32) -> (i32, i32) {
    return (op_fn(a.scale(2), bonus), op_fn(b.scale(2), bonus))
}
pub fn <T impl Scalable> pair_of(a: T, b: T) -> Pair {
    return Pair { lo: a.scale(1), hi: b.scale(1) }
}
pub fn <T impl Scalable, U impl Bumpable> both(a: T, u: U) -> (i32, i32) {
    return (a.scale(3), u.bump())
}

fn main() -> i32 {
    var m1 = Metric { base: 3 }
    var m2 = Metric { base: 5 }
    var (l, r) = tuple_of(m1, m2, 10, add)   // 16, 20
    var p = pair_of(m1, m2)                  // 3, 5
    var (s, b) = both(m2, m1)                // 15, 4
    var lo = p.lo
    var hi = p.hi
    return l + r + lo + hi + s + b - 1       // 62
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/requires_paren.k
// The declarations, then the bodies: the clause closes before the `::`.
// CXX: template<class T> requires{{ ?}}({{ ?}}::{{.*}}::Scalable_c<T>){{ ?}}::builtin::Tuple2<signed int, signed int> tuple_of(
// CXX: template<class T> requires{{ ?}}({{ ?}}::{{.*}}::Scalable_c<T>){{ ?}}::{{.*}}::Pair pair_of(
// CXX: requires{{ ?}}({{ ?}}::{{.*}}::Scalable_c<T> && {{ ?}}::{{.*}}::Bumpable_c<U>){{ ?}}::builtin::Tuple2<signed int, signed int> both(
// CXX: template<class T> requires{{ ?}}({{ ?}}::{{.*}}::Scalable_c<T>){{ ?}}::builtin::Tuple2<signed int, signed int> tuple_of(
// CXX-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 62
