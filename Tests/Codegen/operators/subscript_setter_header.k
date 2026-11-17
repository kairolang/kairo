// The setter form of `op []=` in an emitted header. It is the member
// `__kairo_op_put`, beside `__kairo_op_get` and `__kairo_op_set`, and gets
// no `operator[]` forwarder: `operator[]` takes one operand. The read form
// and the place form keep theirs, so C++ subscripts the type as it did, and
// stores through the setter by name. clang compiles a C++ file that does.

pub class Buf {
    pub var d: [i32; 4]
    pub fn Buf(self) { self.d = [1, 2, 3, 4] }
    pub fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    pub fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
    pub fn op []= (self, const i: usize, v: i32) { self.d[i] = v }
}

pub class Sink {
    pub var last: i32 = 0
    pub fn Sink(self) { }
    pub fn op [] (self, i: usize) -> i32 { return self.last }
    pub fn op []= (self, i: usize, v: i32) { self.last = v }
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h
// RUN: %FileCheck %s --check-prefix=HDR < %t.d/h/subscript_setter_header.hh
// HDR: class Buf
// HDR-DAG: __kairo_op_get(decltype(sizeof(0)) i) const noexcept;
// HDR-DAG: signed int& __kairo_op_set(decltype(sizeof(0)) i) noexcept;
// HDR-DAG: void __kairo_op_put(const decltype(sizeof(0)) i, signed int v) noexcept;
// HDR-DAG: const signed int& operator[](decltype(sizeof(0)) i) const noexcept;
// HDR-DAG: signed int& operator[](decltype(sizeof(0)) i) noexcept;
// HDR: class Sink
// HDR-DAG: signed int __kairo_op_get(decltype(sizeof(0)) i) noexcept;
// HDR-DAG: void __kairo_op_put(decltype(sizeof(0)) i, signed int v) noexcept;
// HDR-DAG: signed int operator[](decltype(sizeof(0)) i) noexcept;
// RUN: %FileCheck %s --check-prefix=ONE < %t.d/h/subscript_setter_header.hh
// ONE-NOT: operator[]({{.*}}signed int v)
// RUN: printf '#include "h/subscript_setter_header.hh"\nint f() { subscript_setter_header::Buf b; b.__kairo_op_put(1, 5); b[2] = 6; const subscript_setter_header::Buf& c = b; subscript_setter_header::Sink s; s.__kairo_op_put(0, 7); return c[1] + s[0]; }\n' > %t.d/use.cc
// RUN: { %clangxx -std=c++23 -fsyntax-only %t.d/use.cc 2>&1 || true; } | %FileCheck %s --check-prefix=CXX --allow-empty
// CXX-NOT: error
