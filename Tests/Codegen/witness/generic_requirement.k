// witness/generic_requirement.k -- exit 33
// A GENERIC requirement, `fn <U> put(self, u: U)`: the witness member is a
// member template, its gate the callable form (no member pointer exists
// without U), and it is left out of the concept (CODEGEN.md §7b.3, §7b.7).
// A concrete argument spells the call's arguments (`template put<signed
// long>`); a dependent one leaves them to deduction. The requirement's
// instance is never an explicit instantiation (§7b.8). Counter conforms by
// an extension member (a specialization), Tally by its own (the primary).
pub interface Sink {
    fn <U> put(self, u: U) -> i32
}
pub struct Counter {
    pub var n: i32
}
extend Counter {
    pub fn <U> put(self, u: U) -> i32 { self.n += sizeof(U) as i32; return self.n; }
}
pub class Tally {
    pub var n: i32 = 0
    fn Tally(self) { }
    pub fn <U> put(self, u: U) -> i32 { self.n += 1; return self.n; }
}
pub fn <T impl Sink, V> feed(s: T, v: V) -> i32 {
    var c = s
    c.put(v)
    return c.put(v)
}
pub fn <T impl Sink> feed_wide(s: T) -> i32 {
    var c = s
    return c.put(0 as i64)
}
fn main() -> i32 {
    var t = Tally()
    return feed(Counter { n: 0 }, 2 as i16) + feed(t, true) * 10 + feed_wide(Counter { n: 1 })
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/generic_requirement.k
// CXX: concept Sink_c = true;
// CXX: template<class U> static signed int put(__kairo_Self * self, U u) requires requires {
// CXX-NEXT: self->template put<U>(static_cast<decltype(u) &&>(u));
// CXX: template<> struct Sink_witness<{{ ?}}::{{.*}}::Counter> {
// CXX-NEXT: template<class U> static signed int put({{ ?}}::{{.*}}::Counter * self, U u) {
// CXX-NEXT: return{{ ?}}::{{.*}}::__kairo_ext_Counter::put<U>(self, static_cast<decltype(u) &&>(u));
// CXX-NOT: template<> struct Sink_witness<{{ ?}}::{{.*}}::Tally>
// CXX: Sink_witness<T>::put((& c), v);
// CXX: Sink_witness<T>::template put<signed long>((& c),
// CXX-NOT: template {{.*}}put<signed long>
// CXX-NOT: template {{.*}}Sink_witness

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 33
