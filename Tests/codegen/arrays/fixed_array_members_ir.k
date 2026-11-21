// A fixed array's member is its slice view's, called on a view built over
// the array's own storage: the emitted C++ constructs the Slice from the
// array's first element and its extent, and copies no array. `size()` and
// `is_empty()` are the extent, emitted as the constant with no call.

fn order(@inout a: [i32; 4]) {
    a.sort()
}

fn count(const a: [i32; 4]) -> usize {
    return a.size()
}

fn empty(const a: [i32; 4]) -> bool {
    return a.is_empty()
}

fn has(const a: [i32; 4]) -> bool {
    return 3 in a
}

fn same(const a: [i32; 4], const b: [i32; 4]) -> bool {
    return a == b
}

fn main() -> i32 {
    var a: [i32; 4] = [4, 3, 2, 1]
    order(&a)
    return count(a) as i32
}

// --- lit wiring ---
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s
// CHECK-LABEL: void order(signed int(& a)[4]) noexcept {
// CHECK-NEXT:  ::builtin::containers::slice::Slice<signed int>(&(a)[0], 4).sort();
// CHECK-LABEL: count(const signed int(& a)[4]) noexcept {
// CHECK-NEXT:  return 4;
// CHECK-LABEL: bool empty(const signed int(& a)[4]) noexcept {
// CHECK-NEXT:  return false;
// CHECK-LABEL: bool has(const signed int(& a)[4]) noexcept {
// CHECK-NEXT:  __kairo_contains<const signed int>( ::builtin::containers::slice::Slice<const signed int>(&(a)[0], 4), 3);
// CHECK-LABEL: bool same(const signed int(& a)[4], const signed int(& b)[4]) noexcept {
// CHECK-NEXT:  __kairo_op_eq<const signed int>( ::builtin::containers::slice::Slice<const signed int>(&(a)[0], 4), {{.*}}Slice<const signed int>(&(b)[0], 4));
// CHECK-LABEL: int main() noexcept {
// CHECK:       fixed_array_members_ir::order(a);
