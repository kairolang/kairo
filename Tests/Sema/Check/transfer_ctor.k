class Handle {
    pub var fd: i32

    pub fn Handle(self, fd: i32) { self.fd = fd }
    @move fn Handle(self, other: Self) { self.fd = other.fd; other.fd = -1 }
    fn op delete(self) { }
}

class Plain {
    pub var n: i32

    pub fn Plain(self, n: i32) { self.n = n }
    @copy fn Plain(self, const other: Self) { self.n = other.n }
}

class Wrapped {
    pub var n: i32

    pub fn Wrapped(self, n: i32) { self.n = n }
    pub fn Wrapped(self, other: Self, extra: i32) { self.n = other.n + extra }
}

fn make(fd: i32) -> Handle { return Handle(fd) }

fn main() -> i32 {
    var h = make(3)
    var g = Handle(h)
    var p = Plain(4)
    var q = Plain(p)
    var w = Wrapped(Wrapped(1), 2)
    return g.fd + q.n + w.n           // 3 + 4 + 3 == 10
}

// --- lit wiring -----------------------------------------------------------
// A transfer constructor is spelled only `@copy fn` / `@move fn` with a bare
// `other: Self`; ClassLifecycle stamps `other` with the mode the marker means
// and the C++ shape follows from that. `Wrapped` takes Self first but `extra`
// has no default, so it is an ordinary constructor and passes by value.
// `Handle(h)` moves: a `@move` argument is written bare at the call site.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: Handle({{.*}}Handle&& other);
// CXX: Plain(const{{.*}}Plain& other);
// CXX: Wrapped({{.*}}Wrapped other, signed int extra);

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 10
