// witness/generic_operator.k -- exit 47
// GENERIC operator requirements, `fn <K> op []` and `fn <U> op +`: each
// witness member is a member template named as a static operator member is
// (`__kairo_op_index` for `[]`, which has no extension form), gated on the
// callable form `self.template operator[]<K>(k)` and left out of the concept
// (CODEGEN.md §7b.3, §7b.7). A subscript on a bounded T is the bound's
// requirement, as a binary operator's is. Table meets both by its own
// members (the primary serves); Grid by an own `op []` spelled with another
// parameter name and an extension `op +` (a specialization). A concrete
// call spells its arguments; a dependent one leaves them to deduction.
pub interface Lookup {
    fn <K> op [](const self, k: K) -> i32
    fn <U> op + (const self, u: U) -> i32
}
pub class Table {
    fn Table(self) { }
    pub fn <K> op [](const self, k: K) -> i32 = sizeof(K) as i32
    pub fn <U> op + (const self, u: U) -> i32 = 10
}
pub struct Grid {
    pub var w: i32
    pub fn <J> op [](const self, j: J) -> i32 = self.w
}
extend Grid {
    pub fn <U> op + (const self, u: U) -> i32 = self.w * 10
}
pub fn <T impl Lookup> probe(t: T) -> i32 { return t[1] + t[true] + (t + 2.5) }
pub fn <T impl Lookup, V> probe_dep(t: T, v: V) -> i32 { return t[v] }
fn main() -> i32 {
    var t = Table()
    return probe(t) + probe(Grid { w: 2 }) + probe_dep(t, 1 as i64)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/generic_operator.k
// CXX: concept Lookup_c = true;
// CXX: template<class K> static signed int __kairo_op_index(const __kairo_Self & self, K k) requires requires {
// CXX-NEXT: self.template operator[]<K>(static_cast<decltype(k) &&>(k));
// CXX: template<class U> static signed int __kairo_op_plus(const __kairo_Self & self, U u) requires requires {
// CXX-NEXT: self.template operator +<U>(static_cast<decltype(u) &&>(u));
// CXX-NOT: template<> struct Lookup_witness<{{ ?}}::{{.*}}::Table>
// CXX: template<> struct Lookup_witness<{{ ?}}::{{.*}}::Grid> {
// CXX-NEXT: template<class K> static signed int __kairo_op_index(const{{ ?}}::{{.*}}::Grid & self, K k) {
// CXX-NEXT: return self.operator[]<K>(static_cast<decltype(k) &&>(k));
// CXX: template<class U> static signed int __kairo_op_plus(const{{ ?}}::{{.*}}::Grid & self, U u) {
// CXX-NEXT: return{{ ?}}::{{.*}}::__kairo_ext_Grid::__kairo_op_plus<U>(self, static_cast<decltype(u) &&>(u));
// CXX-NOT: template<> struct Lookup_witness<{{ ?}}::{{.*}}::Table>
// CXX: Lookup_witness<T>::template __kairo_op_index<signed int>(t, 1)
// CXX-SAME: Lookup_witness<T>::template __kairo_op_index<bool>(t, true)
// CXX-SAME: Lookup_witness<T>::template __kairo_op_plus<double>(t, 2.5)
// CXX: Lookup_witness<T>::__kairo_op_index(t, v);
// CXX-NOT: template {{.*}}__kairo_op_index<
// CXX-NOT: template {{.*}}Lookup_witness

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 47
