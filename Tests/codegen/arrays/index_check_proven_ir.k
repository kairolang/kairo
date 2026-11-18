// Which fixed-array subscripts carry a run-time bounds check in the emitted
// C++: an index proven in range (a constant, the binder of a `for` over a
// constant range inside the extent that the body never writes, the
// lowering's own index of `for x in a`) is a plain subscript; any other
// index goes through `__kairo_ix` with the extent, a generic one by name.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s

fn konst(const a: [i32; 3]) -> i32 { return a[2] }

fn looped(const a: [i32; 3]) -> i32 {
    var s = 0
    for i in 0..3 { s += a[i] }
    for j in 1..=2 { s += a[j] }
    for x in a { s += x }
    return s
}

fn too_far(const a: [i32; 3]) -> i32 {
    var s = 0
    for i in 0..4 { s += a[i] }
    return s
}

fn rewritten(const a: [i32; 3]) -> i32 {
    var s = 0
    for i in 0..3 { i += 1; s += a[i] }
    return s
}

fn runtime(const a: [i32; 3], i: usize) -> i32 { return a[i] }

fn <T, eval N: usize> gen(const a: [T; N], i: usize) -> T { return a[i] }

fn main() -> i32 {
    var a: [i32; 3] = [1, 2, 3]
    return konst(a) + looped(a) + too_far(a) + rewritten(a) + runtime(a, 1) + gen(a, 0)
}

// CHECK: CODEGEN C++: {{.*}}index_check_proven_ir.k
// CHECK: constexpr I __kairo_ix(I i, decltype(sizeof(0)) n) noexcept {
// CHECK-LABEL: signed int konst(const signed int(& a)[3]) noexcept {
// CHECK-NEXT: return a[2];
// CHECK-LABEL: signed int looped(const signed int(& a)[3]) noexcept {
// CHECK-NOT: __kairo_ix
// CHECK: static_cast<unsigned int>(a[i])
// CHECK-NOT: __kairo_ix
// CHECK: static_cast<unsigned int>(a[j])
// CHECK-NOT: __kairo_ix
// CHECK: signed int x = a[__kairo_k{{[0-9]+}}];
// CHECK-LABEL: signed int too_far(const signed int(& a)[3]) noexcept {
// CHECK: a[ ::__kairo_ix(i, 3)]
// CHECK-LABEL: signed int rewritten(const signed int(& a)[3]) noexcept {
// CHECK: a[ ::__kairo_ix(i, 3)]
// CHECK-LABEL: signed int runtime(const signed int(& a)[3], decltype(sizeof(0)) i) noexcept {
// CHECK-NEXT: return a[ ::__kairo_ix(i, 3)];
// CHECK-LABEL: T gen(const T(& a)[N], decltype(sizeof(0)) i) noexcept {
// CHECK-NEXT: return a[ ::__kairo_ix(i, N)];
