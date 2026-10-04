class Counter {
    var n: i32

    pub fn Counter(self, n: i32) { self.n = n }

    pub fn op in (self) -> yield i32 {
        for i in 0..self.n { yield i }
    }
}

fn main() -> i32 {
    var c = Counter(5)
    var s: i32 = 0
    for x in c { s += x }               // 10
    for x in Counter(3) { s += x }      // 3: the prvalue receiver is bound first
    return s                            // 13
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: __kairo_iter()
// CXX: .next()
// CXX: .current()

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o3
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 13

// A method generator's frame holds a pointer to self rather than a copy,
// the case that could defeat clang's escape check: -O3 must still elide it.
// RUN: %kairo %s -c -O3 --cache-dir %t.o3
// RUN: objdump -dr --no-show-raw-insn %t.o3/user.o | awk '/<main>:/,/^$/' | { ! grep -q _Znwm; }
