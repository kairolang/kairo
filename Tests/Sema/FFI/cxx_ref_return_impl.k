// A Kairo override of a C++ virtual returning `T&` / `const T&` is written
// `-> *T` / `-> *const T` (an imported reference return is a pointer in
// Kairo, functions-parameter-modes.mdx): the C++ declaration keeps the
// reference, `return &x` returns x, and a Kairo call of the override takes
// the reference's address back. It used to emit `int * pick() override`,
// which clang rejects (CXX-REF, decided 2026-11-08). The same `-> *T` defines
// an imported member declared `int& slot();` out of line without R037E
// (the definition is type-checked here only: an out-of-line definition of
// an imported member is not emitted yet).

ffi "c++" import "cxx_ref_return_impl.h"

fn S::slot(self) -> *i32 { return &self.v }

class D derives Base {
    pub var mine: i32 = 1
    override fn pick(self) -> *i32 { return &self.mine }
    override fn peek(const self) -> *const i32 { return &self.mine }
}

fn main() -> i32 {
    var d = D()
    var b = use_base(&d)                     // pick() = 40 writes d.mine; 40 + 40
    var *p = d.pick()                        // a Kairo call of the override: the pointer
    (*p) += 1                                // d.mine = 41
    // 80 + 41 = 121
    return b + d.mine
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: { %kairo %s --print-ir -o /dev/null 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR: virtual signed int & pick() noexcept override;
// IR: virtual const signed int & peek() const noexcept override;
// IR: signed int & D::pick() noexcept {
// IR-NEXT: return this->mine;
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 121
