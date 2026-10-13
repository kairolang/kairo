// A special member declared `= default` or `= delete` is declared that way
// in the class, and gets no definition out of line: C++ generates the
// defaulted one, and a deleted one has none. A `requires` written on a
// member is Kairo's to check and never reaches the C++, so Cell's get() is
// declared without one.

class Pair {
    pub var a: i32
    pub var b: i32
    fn Pair(self, a: i32, b: i32) {
        self.a = a
        self.b = b
    }
    @copy
    fn Pair(self, const other: Self) = default
    fn op delete(self) = default
}

class Pinned {
    pub var n: i32
    fn Pinned(self, n: i32) { self.n = n }
    @copy
    fn Pinned(self, const other: Self) = delete
    @move
    fn Pinned(self, other: Self) = delete
}

class <T> Cell {
    pub var v: T
    fn Cell(self, v: T) { self.v = v }
    @copy
    fn Cell(self, const other: Self) = default
    fn get(const self) -> T requires sizeof T <= 8 { return self.v }
}

fn main() -> i32 {
    var p = Pair(3, 4)
    var q = p                       // the defaulted copy
    var k = Pinned(2)
    var c = Cell<i32>(5)
    var d = c                       // the defaulted copy, in an instance
    return q.a + q.b + k.n + d.get()        // 3 + 4 + 2 + 5 == 14
}

// --- lit wiring -----------------------------------------------------------
// Pinned deletes both transfer constructors, the one form in which a class
// may declare both; it is built in place and never transferred.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}special_members.k
// CXX:       class Pair {
// CXX:       Pair({{.*}}Pair& other) = default;
// CXX-NEXT:  ~Pair() = default;
// CXX:       class Pinned {
// CXX:       Pinned({{.*}}Pinned& other) = delete;
// CXX-NEXT:  Pinned({{.*}}Pinned&& other) = delete;
// CXX:       template<class T> class Cell {
// CXX:       Cell({{.*}}Cell<T>& other) = default;
// CXX-NEXT:  T get() const;
// CXX-NOT:   requires

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}special_members.k
// IR:       Pair::Pair(signed int a, signed int b) {
// IR-NOT:   Pair::Pair({{.*}}other)
// IR-NOT:   Pair::~Pair
// IR:       Pinned::Pinned(signed int n) {
// IR-NOT:   Pinned::Pinned({{.*}}other)
// IR:       Cell<T>::Cell(T v) {
// IR-NOT:   Cell<T>::Cell({{.*}}other)
// IR:       Cell<T>::get() const {

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 14
