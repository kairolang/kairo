// `op []` is a place when it returns `*T` / `*const T` and a value
// otherwise. One record carries both: the index forms are places (C++ gets
// `T&`), the range form returns a plain `i32` and is spelled as declared.

struct Buf {
    var data: [i32; 4]

    pub fn op [] (self, i: usize) -> *i32 { return &self.data[i] }
    pub fn op [] (const self, i: usize) -> *const i32 { return &self.data[i] }

    pub fn op [] (self, r: Range<usize>) -> i32 {
        var s: i32 = 0
        for k in r.begin..r.end { s += self.data[k] }
        return s
    }
}

fn read(const b: Buf) -> i32 { return b[3] }

fn main() -> i32 {
    var b = Buf { data: [1, 2, 3, 4] }
    b[0] = 10                                // place: assignable
    var v = b[1..3]                          // value: 2 + 3
    return b[0] + v + read(b)                // 10 + 5 + 4 == 19
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: signed int& operator[](
// CXX-DAG: const signed int& operator[](
// CXX-DAG: signed int operator[](
// CXX-NOT: signed int* operator[](

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 19
