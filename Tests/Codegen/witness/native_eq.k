// witness/native_eq.k -- exit 15
// An `op ==` requirement met by an operator with no Kairo decl
// (ConformanceChecking::_native_implementation): a builtin's and a
// pointer's own `==`, and an imported C++ record's (std::string's is a free
// operator template). The requirement stands as its own witness, and the
// specialization's member is the native comparison (EmitWitness::_target).
// A pointer conformer is named through a member alias, so `const Self` is
// the pointer made const, not a pointer to const.
ffi "c++" import "string"

pub interface Same {
    fn op ==(const self, const other: Self) -> bool
}
fn <T impl Same> same(const a: T, const b: T) -> bool = a == b

fn main() -> i32 {
    var r = 0
    var x: i32 = 4
    if same(x, x) && !same(x, 5) { r += 1 }
    var d: f64 = 1.5
    if same(d, d) { r += 2 }
    var p: unsafe *i32 = &null
    if same(p, p) { r += 4 }
    var s = cxx::std::string()
    if same(s, cxx::std::string()) { r += 8 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/native_eq.k
// CXX: template<> struct Same_witness<signed int> {
// CXX-NEXT: static bool __kairo_op_eq(const signed int & self, const signed int & other) noexcept {
// CXX-NEXT: return(self == static_cast<decltype(other) &&>(other));
// CXX: template<> struct Same_witness<signed int *> {
// CXX-NEXT: using __kairo_Self = signed int *;
// CXX-NEXT: static bool __kairo_op_eq(const __kairo_Self & self, const __kairo_Self & other) noexcept {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15
