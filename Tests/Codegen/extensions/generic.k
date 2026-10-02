// generic.k -- exit 4
struct <T> Cell { var x: T; var n: i32; }

extend <T> Cell<T> {
    fn put(self, v: T) { self.x = v; self.n += 1; }
    fn get(const self) -> T { return self.x; }
    fn <U> map(const self, f: fn(T) -> U) -> Cell<U> { return Cell<U> { x: f(self.x), n: self.n }; }
    static fn make(v: T) -> Cell<T> { return Cell<T> { x: v, n: 0 }; }
}

fn halve(x: i64) -> f64 { return (x as f64) / 2.0; }

fn main() -> i32 {
    var a = Cell<i64>::make(0);
    var b = Cell<f64> { x: 0.0, n: 0 };
    var r: i32 = 0;
    a.put(40);
    b.put(1.5);
    var c = a.map(halve);
    if a.get() == 40        { r += 1; }
    if b.get() == 1.5       { r += 1; }
    if c.get() == 20.0      { r += 1; }
    if a.n + b.n + c.n == 3 { r += 1; }
    return r;
}

// --- lit wiring -----------------------------------------------------------
// A generic extension is one scope struct of static member templates, the
// extension's T merged ahead of a member's own U. The named initializers of
// DEPENDENT records (`Cell<U> { ... }` in `map`, `Cell<T> { ... }` in
// `make`) are typed with that record, not left unknown -- EmitIR used to ICE
// on them. `f: fn(T) -> U` keeps its name inside the declarator, and the
// explicit instantiations parenthesize theirs (a class-template return
// would otherwise swallow the leading `::generic::`).

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      friend struct::generic::__kairo_ext_Cell;
// CXX:      struct __kairo_ext_Cell {
// CXX-NEXT:   template<class T> static void put( ::generic::Cell<T> * self, T v);
// CXX-NEXT:   template<class T> static T get(const::generic::Cell<T> * self);
// CXX-NEXT:   template<class T, class U> static::generic::Cell<U> map(const::generic::Cell<T> * self, U(* f)(T));
// CXX-NEXT:   template<class T> static::generic::Cell<T> make(T v);
// CXX:      template<class T, class U>::generic::Cell<U> __kairo_ext_Cell::map(
// CXX:      return::generic::Cell<U> {
// CXX:      template<class T>::generic::Cell<T> __kairo_ext_Cell::make(T v) {
// CXX-NEXT: return::generic::Cell<T> {
// CXX:      ::generic::__kairo_ext_Cell::make<signed long>(0);
// CXX:      ::generic::__kairo_ext_Cell::map<signed long, double>((& a), ::generic::halve);
// CXX:      template void({{ *}}::generic::__kairo_ext_Cell::put<signed long>)(
// CXX:      template signed long({{ *}}::generic::__kairo_ext_Cell::get<signed long>)(
// CXX:      template::generic::Cell<double>({{ *}}::generic::__kairo_ext_Cell::map<signed long, double>)(const::generic::Cell<signed long> *, double(*)(signed long));
// CXX:      template::generic::Cell<signed long>({{ *}}::generic::__kairo_ext_Cell::make<signed long>)(signed long);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 4
