// witness/operator.k -- exit 1
// An operator on a bounded `T` goes through the witness too, under the
// extension-operator name: `a == b` is `::N::Same_witness<T>::__kairo_op_eq(a, b)`
// (CODEGEN.md §7b.5). The primary and the specialization already carry the
// member.
//
// XFAIL: *
// Waiting on OperatorTyping: on a bounded `T` it binds no `resolved_op`,
// so OperatorLowering leaves `a == b` a builtin operator and it reaches C++
// as `a == b`. That links here only because ADL finds the extension's
// namespace-scope `operator==` forwarder in P's namespace; a builtin
// conformer, or an extension in another module, would not. When the
// operator binds to the requirement, OperatorLowering turns it into a call
// and ExtensionLowering's witness arm takes it: this XPASSes, drop the XFAIL.
pub interface Same {
    fn op ==(const self, other: Self) -> bool
}
pub struct P {
    pub var v: i32
}
extend P {
    pub fn op ==(const self, other: P) -> bool = self.v == other.v
}
pub fn <T impl Same> eq(a: T, b: T) -> i32 {
    if a == b { return 1 }
    return 0
}
fn main() -> i32 {
    return eq(P { v: 2 }, P { v: 2 }) + eq(P { v: 2 }, P { v: 3 }) * 10
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: static bool __kairo_op_eq(const __kairo_Self & self, __kairo_Self other) requires requires {
// CXX: template<> struct Same_witness<{{ ?}}::{{.*}}::P> {
// CXX: Same_witness<T>::__kairo_op_eq(a, b)

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 1
