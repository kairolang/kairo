// where/method_explicit.k -- exit 0 (P207, P263)
// A generic `where` group of METHODS whose parameters C++ cannot deduce
// from the forwarded arguments: a type parameter no parameter's type
// mentions, and a value parameter. The dispatcher calls each candidate
// through `self` with its own parameters written as the arguments
// (`this->template __kairo_where_width_0<T>(n)`), as a free one does.

class C {
    var base: i32 = 0
    fn <T> width(self, n: i32) -> usize where n > 0 { return sizeof T }
    fn <T> width(self, n: i32) -> usize { return 0 }

    fn <eval N: i32> above(self, x: i32) -> i32 where x > N { return 1 + self.base }
    fn <eval N: i32> above(self, x: i32) -> i32 { return self.base }
}

fn main() -> i32 {
    var c = C()
    var r = 0
    if c.width<i64>(7) != 8    { r += 1 }
    if c.width<i32>(-3) != 0   { r += 2 }
    if c.above<5>(9) != 1      { r += 4 }
    if c.above<5>(2) != 0      { r += 8 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: return{{.*}}this->template __kairo_where_width_0<T>(n);
// CXX: return{{.*}}this->template __kairo_where_width_1<T>(n);
// CXX: return{{.*}}this->template __kairo_where_above_0<N>(x);
// CXX-NOT: {{(error|warning) @}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
