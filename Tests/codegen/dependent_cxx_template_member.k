// A member of a C++ class template instance over a Kairo parameter
// (`self.v.push_back(x)`, `self.v[i]`, `self.v.size()` on a `vector<T>`) is
// decided per instance, so it goes out as written and clang resolves it in
// each one. The field spells as `vector<T>` alone: the defaulted
// allocator still names T and is left to C++.

ffi "c++" import "vector";

class <T> Box {
    pub var v: cxx::std::vector<T>;
    fn add(self, x: T) { self.v.push_back(x); }
    fn at(self, i: usize) -> T { return self.v[i]; }
    fn count(self) -> usize { return self.v.size(); }
}

fn main() -> i32 {
    var b: Box<i32>;
    b.add(3); b.add(4); b.v.push_back(5);
    var p: Box<u8>;
    p.add(1);
    return b.at(1) * 10 + (b.count() as i32) + (p.at(0) as i32) * 100;   // 143
}

// --- lit wiring ---
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 143
// CXX: ::std::vector<T> v;
// CXX: this->v.push_back(
// CXX: this->v[i]
// CXX: this->v.size()
// CXX: b.v.push_back(5);
