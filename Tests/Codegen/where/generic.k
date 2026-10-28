// where/generic.k -- exit 0
// A `where` group on generic functions (where.mdx; MONO.md G12). Overloads
// equal up to the names of their generic parameters are one group, folded
// like any other: the dispatcher is the lead's template, each candidate a
// template over its member's parameters, called with its arguments left to
// C++ deduction. A guard is an ordinary run-time `if`, also when it reads
// only a parameter's type (`sizeof T > 4`): under D0 every candidate is
// valid for every argument the shared bounds admit, so nothing per instance
// needs selecting, and clang folds the constant.
pub interface Sized {
    fn weight(const self) -> i32
}
pub struct Light {
    pub var w: i32
}
extend Light {
    pub fn weight(const self) -> i32 = self.w
}

// A runtime guard on a plain parameter.
fn <T> pick(x: T, n: i32) -> i32 where n > 0 { return 1 }
fn <T> pick(x: T, n: i32) -> i32 { return 2 }

// A guard on the parameter's type alone: per instance, but constant.
fn <T> width(x: T) -> i32 where sizeof T > 4 { return 8 }
fn <T> width(x: T) -> i32 { return 4 }

// Bounded: each member calls through the (shared) bound.
fn <T impl Sized> heavy(x: T) -> i32 where x.weight() > 10 { return x.weight() * 2 }
fn <T impl Sized> heavy(x: T) -> i32 { return x.weight() }

// Two parameters, one group of three.
fn <A, B> order(a: A, b: B, k: i32) -> i32 where k > 100 { return 3 }
fn <A, B> order(a: A, b: B, k: i32) -> i32 where k > 0   { return 2 }
fn <A, B> order(a: A, b: B, k: i32) -> i32               { return 1 }

fn main() -> i32 {
    var r = 0
    if pick(1.5, 3) != 1       { r += 1 }
    if pick(true, -1) != 2     { r += 2 }
    var big: i64 = 1
    var small: i32 = 1
    if width(big) != 8         { r += 4 }
    if width(small) != 4       { r += 8 }
    if heavy(Light { w: 20 }) != 40 { r += 16 }
    if heavy(Light { w: 3 }) != 3   { r += 32 }
    if order(1, 2.0, 500) != 3      { r += 64 }
    if order(1, 2.0, 5) != 2        { r += 128 }
    if order(true, 1, -5) != 1      { r += 256 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<class T> {{.*}}__kairo_where_pick_0(T x, signed int n)
// CXX: if({{.*}}sizeof(T){{.*}}> 4

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
