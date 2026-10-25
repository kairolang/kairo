// partial_spec_header/app.k -- exit 123
// NULLABLE.md G0 across a module boundary: store.k's primary, its `<P>
// Store<*P>` partial and its `<> Store<bool>` explicit spec, used from
// another file. The importer's preamble and store's `--emit-headers` header
// both carry every specialization after the primary (a TU that saw only the
// primary would instantiate it for `Store<int*>`, an ODR violation no linker
// reports), and host.cc compiles against the header alone.
import store::Store
fn <T> f(s: Store<T>) -> i32 = s.tag()
fn main() -> i32 {
    var n = 4
    var b = Store<*i32>(&n)
    var c = Store<bool>(true)
    var a = Store<i32>(7)
    if !c.on() { return 90 }
    if b.read() != 4 { return 91 }
    return f(a) * 100 + f(b) * 10 + f(c)
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.h
// RUN: %kairo %s -o %t.exe --cache-dir %t.d --emit-headers=%t.h
// RUN: %t.exe; test $? -eq 123
// RUN: cat %t.h/store.hh | %FileCheck %s --check-prefix=HDR
// HDR: template<class T> class Store;
// HDR-NEXT: template<class P> class Store<P*>;
// HDR-NEXT: template<> class Store<bool>;
// HDR: template<class P> class Store<P*> {
// HDR: template<> class Store<bool> {
// HDR: static bool on(const{{ ?}}::store::Store<bool>* self);
// HDR: template<class P> static P read(const{{ ?}}::store::Store<P*>* self);
// HDR: template<class P> signed int Store<P*>::tag() const {
// The explicit spec's members are ordinary functions: defined in store's
// object, only declared here.
// HDR-NOT: Store<bool>::tag() const {
// RUN: %clangxx -std=c++23 -fsyntax-only -I%t.h %S/host.cc
// RUN: not %clangxx -std=c++23 -fsyntax-only -I%t.h -DWRONG %S/host.cc 2>&1 | %FileCheck %s --check-prefix=WRONG
// WRONG: no member named 'value'
