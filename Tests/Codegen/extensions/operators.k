// operators.k -- exit 7
struct Num { var v: i32; }

extend Num {
    fn op == (const self, const o: Num) -> bool { return self.v == o.v; }
    fn op - (self) -> i32 { self.v = -self.v; return self.v; }
    fn op += (self, x: i32) { self.v += x; }
    fn op r++ (self) -> i32 { self.v += 1; return self.v - 1; }
}

fn mk(v: i32) -> Num { return Num { v: v }; }

fn main() -> i32 {
    var a = Num { v: 3 };
    var p: *Num = &a;
    var r: i32 = 0;
    if a == mk(3)     { r += 1; }
    if mk(3) == a     { r += 1; }
    if -mk(4) == -4   { r += 1; }
    if -(*p) == -3    { r += 1; }
    a += 2;
    if a.v == -1      { r += 1; }
    var c = a + 3;
    if (c.v == 2) && (a.v == -1) { r += 1; }
    if (a++ == -1) && (a.v == 0) { r += 1; }
    return r;
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// An extension operator is a static member spelled by mnemonic, and the
// C++ operator is a forwarder in the file's namespace. A pointer operand is
// dereferenced, not re-addressed; a prvalue one is `*__kairo_tmp(...)`.
// CXX: struct __kairo_ext_Num {
// CXX: inline bool operator ==(const::operators::Num & __kairo_a0, const::operators::Num & __kairo_a1) {
// CXX: inline signed int operator -( ::operators::Num & __kairo_a0) {
// CXX: inline void operator +=( ::operators::Num & __kairo_a0, signed int __kairo_a1) {
// CXX: inline signed int operator++( ::operators::Num & __kairo_a0, int __kairo_a1) {
// CXX: int main() {
// CXX: __kairo_ext_Num::__kairo_op_eq(a, ::operators::mk(3))
// CXX: __kairo_ext_Num::__kairo_op_minus((* ::__kairo_tmp( ::operators::mk(4))))
// CXX: __kairo_ext_Num::__kairo_op_minus((* p))
// CXX: __kairo_ext_Num::__kairo_op_postinc(a, 0)

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 7
