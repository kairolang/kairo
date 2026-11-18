// generics/method_explicit_args.k -- exit 0
// A generic method called through its receiver keeps its generic
// arguments: `c.m<i64>()` was written to C++ as `c.m()`, and clang could
// not infer a T no parameter mentions. Every receiver form: a value, a
// pointer, `self` inside a method, a generic record's instance, a value
// parameter, a deduced call (spelled from its instance too), and a call in
// a generic body (no instance: the written arguments).

class C {
    var k: i32 = 1
    fn <T> m(self) -> i32 { return sizeof T as i32 }
    fn <eval N: i32> v(self) -> i32 { return N + self.k }
    fn <T> d(self, x: T) -> i32 { return sizeof T as i32 }
    fn <T> via_self(self) -> i32 { return self.m<T>() * 10 }
}

class <X> Box {
    var x: X
    fn Box(self, x: X) { self.x = x }
    fn <T> both(self) -> i32 { return (sizeof X + sizeof T) as i32 }
}

fn <T> in_generic(c: C) -> i32 { return c.m<T>() }

fn main() -> i32 {
    var c = C()
    var p: *C = &c
    var h: i16 = 5
    var b = Box<i32>(3)
    if c.m<i64>() != 8           { return 1 }
    if p->m<i16>() != 2          { return 2 }
    if c.via_self<i32>() != 40   { return 3 }
    if b.both<i8>() != 5         { return 4 }
    if c.v<3>() != 4             { return 5 }
    if c.d(h) != 2        { return 6 }
    if in_generic<i64>(c) != 8   { return 7 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR-DAG: c.template m<signed long>()
// IR-DAG: p->template m<signed short>()
// IR-DAG: this->template m<T>()
// IR-DAG: b.template both<signed char>()
// IR-DAG: c.template v<3>()
// IR-DAG: c.template d<signed short>(h)
// IR-DAG: return c.template m<T>();

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
