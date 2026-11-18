// A generic class's `op =` is derived from its transfer constructor
// (ClassLifecycle, AssignForm::Body), and it carries that constructor's
// requires-clause. Every home of an instance writes `template class
// Box<X>;`, which instantiates each unconstrained member: an `op =` that
// rebuilds through a copy constructor C++ dropped for X (its clause is
// false) failed to compile for X even though nothing assigned a Box<X>.
// Box<Mv> is built and used, never copied; Box<i32> is copied and assigned.

class Mv {
    var v: i32
    fn Mv(self, v: i32) { self.v = v }
    @move fn Mv(self, other: Self) = default
}

class <T> Box {
    var n: i32
    fn Box(self, n: i32) { self.n = n }
    @copy
    fn Box(self, const other: Self) requires __builtin_is_constructible<T, const T>() {
        self.n = other.n + 1
    }
    fn op finally(self) { }
}

fn main() -> i32 {
    var m = Box<Mv>(5)
    var a = Box<i32>(1)
    var b = a                                   // copied: 2
    a = b                                       // assigned: 3
    return m.n + a.n                            // 8
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: Box & operator =(const{{.*}}Box<T> & o) noexcept requires(({{.*}}kairo_rt_is_constructible1<T, const T>()))

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 8
