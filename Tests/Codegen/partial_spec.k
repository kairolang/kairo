// partial_spec.k -- exit 123
// NULLABLE.md G0: partial and explicit specializations of a generic record,
// end to end. `<P> Store<*P>` and `<P> Store<*const P>` are C++ partial
// specializations (`template <class P> class Store<P*>`), `<> Store<bool>` an
// explicit one (`template <> class Store<bool>`), each declared after the
// primary and defined with its own members; an instance whose pattern is a
// partial is explicitly instantiated by name, never re-specialized. Sema
// types every member through the selected body: `b.ptr` is the partial's
// field, `*const P` beats `*P` for a `*const i32`, and an extension on a
// specialization (`extend <> Store<bool>`, `extend <P> Store<*P>`) reaches
// the specialization's own private members.
pub class <T> Store {
    pub var value: T
    pub var present: bool = false
    fn Store(self, v: T) { self.value = v; self.present = true }
    pub fn tag(const self) -> i32 = 1
}
pub class <P> Store<*P> {
    priv var ptr: unsafe *P
    fn Store(self, v: *P) { unsafe { self.ptr = v as unsafe *P } }
    pub fn tag(const self) -> i32 = 2
    pub fn same(const self) -> Self {
        unsafe { return Store<*P>(self.ptr as *P) }
    }
}
pub class <P> Store<*const P> {
    pub var cptr: unsafe *const P
    fn Store(self, v: *const P) { unsafe { self.cptr = v as unsafe *const P } }
    pub fn tag(const self) -> i32 = 4
}
pub class <> Store<bool> {
    priv var bits: u8 = 2
    fn Store(self, v: bool) { self.bits = v as u8 }
    pub fn tag(const self) -> i32 = 3
}
extend <> Store<bool> {
    pub fn on(const self) -> bool = self.bits == 1
}
extend <P> Store<*P> {
    pub fn read(const self) -> P {
        unsafe { return *self.ptr }
    }
}
// Two parameters, one fixed: once read as a second primary (R029E).
pub struct <A, B> Pair { pub var a: A; pub var b: B }
pub struct <X> Pair<X, i32> { pub var left: X }
extend <X> Pair<X, i32> {
    pub fn kind(const self) -> i32 = 5
}
fn <T> f(s: Store<T>) -> i32 = s.tag()
fn main() -> i32 {
    var a = Store<i32>(1)
    var n = 4
    var b = Store<*i32>(&n)
    var c = Store<bool>(true)
    var k: i32 = 5
    var d = Store<*const i32>(&k)
    var e = b.same()
    var cp: unsafe *const i32 = d.cptr
    var p = Pair<f64, i32> { left: 2.5 }
    if !c.on() { return 90 }
    if b.read() != 4 { return 91 }
    if e.read() != 4 { return 92 }
    if f(d) != 4 { return 93 }
    if p.kind() != 5 { return 94 }
    unsafe { if *cp != 5 { return 95 } }
    if !a.present { return 96 }
    return f(a) * 100 + f(b) * 10 + f(c)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}partial_spec.k
// Every specialization is declared after its primary, in tier 0.
// CXX: template<class T> class Store;
// CXX-NEXT: template<class P> class Store<P *>;
// CXX-NEXT: template<class P> class Store<const P *>;
// CXX-NEXT: template<> class Store<bool>;
// CXX: template<class X> struct Pair<X, signed int>;
// CXX: template<class P> class Store<P *> {
// CXX-NEXT: P * ptr;
// CXX: {{ ?}}::{{.*}}::Store<P *> same() const;
// CXX: template<class P> class Store<const P *> {
// CXX: template<> class Store<bool> {
// One extension scope holds every specialization's blocks.
// CXX: struct __kairo_ext_Store {
// CXX-NEXT: static bool on(const{{ ?}}::{{.*}}::Store<bool> * self);
// CXX-NEXT: template<class P> static P read(const{{ ?}}::{{.*}}::Store<P *> * self);
// A partial's members are templates over ITS parameters; an explicit
// spec's are ordinary members with no `template <>` (C++ [temp.expl.spec]).
// CXX: template<class P> signed int Store<P *>::tag() const {
// CXX: template<class P> signed int Store<const P *>::tag() const {
// CXX: {{^ *}}Store<bool>::Store(bool v) {
// CXX: {{^ *}}signed int Store<bool>::tag() const {
// The instances are named, never re-specialized; the explicit one is not
// instantiated at all.
// CXX: template class{{ ?}}::{{.*}}::Store<signed int *>;
// CXX: template class{{ ?}}::{{.*}}::Store<const signed int *>;
// CXX-NOT: template class{{ ?}}::{{.*}}::Store<bool>;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 123
