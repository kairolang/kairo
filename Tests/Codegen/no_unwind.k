// `@no_unwind` adds `noexcept` to the function's C++ spelling, and does
// nothing else: on the declaration and the definition alike, which C++
// requires to agree.

class C {
    pub var n: i32
    @no_unwind pub fn get(const self) -> i32 { return self.n }
}

@no_unwind fn add(a: i32, b: i32) -> i32 { return a + b }

fn plain(a: i32) -> i32 { return a }

fn main() -> i32 {
    var c = C { n: 1 }
    return add(c.get(), plain(2))       // 1 + 2 == 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=DECL
// DECL: get() const noexcept;
// DECL: add({{.*}}) noexcept;
// DECL-NOT: plain({{.*}}) noexcept

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=DEF
// DEF: ::get() const noexcept
// DEF: add({{.*}}) noexcept

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 3
