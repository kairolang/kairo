// A MOVE lvalue passed to an imported `T&&` is moved there: C++ needs the
// static_cast Kairo never writes, or overload resolution picks
// push_back(const T&) and the copy it calls is deleted. A prvalue binds
// `T&&` as it is and gets no cast, and a COPY lvalue stays push_back(const
// T&) with none either.

ffi "c++" import "vector"

class Mv {
    pub var n: i32 = 0
    fn Mv(self, n: i32) { self.n = n }
    @move fn Mv(self, other: Self) { self.n = other.n; other.n = 0 }
}

class Cp {
    pub var n: i32 = 0
    fn Cp(self, n: i32) { self.n = n }
}

fn main() -> i32 {
    var v: cxx::std::vector<Mv>
    var c: cxx::std::vector<Cp>
    var m = Mv(5)
    v.push_back(m)
    v.push_back(Mv(7))
    var k = Cp(3)
    c.push_back(k)
    c.push_back(k)
    return v[0].n * 10 + v[1].n + c[0].n + c[1].n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}move_into_rref.k
// IR:      v.push_back(static_cast<{{ ?}}::move_into_rref::Mv &&>(m));
// IR-NEXT: v.push_back({{ ?}}::move_into_rref::Mv(7));
// IR:      c.push_back(k);
// IR-NEXT: c.push_back(k);

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 63
