// OperatorSemantics: the C++ SequenceLowering writes. Every operand before
// the last effectful one that has an effect or reads state is bound in
// order; the last stays in place. A place is bound as `auto&&`, a value
// copied.

fn f() -> i32 { return 1 }
fn g() -> i32 { return 2 }
fn h(a: i32, b: i32) -> i32 { return a + b }
fn i() -> usize { return 0 }

var x: i32 = 0

fn forms(arr: *[i32; 2], local: i32) -> i32 {
    var r = f() - g()
    var c = h(f(), g())
    (*arr)[i()] = g()
    var s = h(x, g())          // a global read before an effect: snapshotted
    var t = h(local, g())      // a local nothing else reaches: left alone
    return r + c + s + t
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}order_forms.k
// CXX: signed int forms(
// CXX: signed int __kairo_ord0 = {{.*}}f();
// CXX-NEXT: static_cast<signed int>(static_cast<unsigned int>(__kairo_ord0) - static_cast<unsigned int>({{.*}}g()));
// CXX: signed int __kairo_ord1 = {{.*}}f();
// CXX-NEXT: h(__kairo_ord1, {{.*}}g());
// CXX: auto && __kairo_ord2 =((* arr)[{{.*}}i()]);
// CXX-NEXT: (__kairo_ord2 = {{.*}}g());
// CXX: signed int __kairo_ord3 = {{.*}}x;
// CXX-NEXT: h(__kairo_ord3, {{.*}}g());
// CXX: signed int t = {{.*}}h(local, {{.*}}g());
