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
// XFAIL: *
// Waiting on M2: a named initializer of a DEPENDENT record type
// (`Cell<U> { ... }` inside `map`, `Cell<T> { ... }` inside `make`) is left
// untyped, as in any generic function, and EmitIR ICEs on it ("untyped
// initializer reached codegen"). Not extension-specific. When it XPASSes,
// drop this and add the CXX block: put<long>, get<long>, map<long, double>,
// make<long>; one `template <class T, class U> static` map inside the scope;
// `friend struct ::generic::__kairo_ext_Cell;`.

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 4
