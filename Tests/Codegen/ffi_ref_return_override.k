ffi "c++" import "ffi_ref_return_override.h"

class D derives Base {
    pub var mine: i32 = 1
    override fn pick(self) -> ffi::ref<i32> { return self.mine }
    override fn peek(const self) -> ffi::ref<const i32> { return self.mine }
    override fn take(self) -> ffi::mref<i32> { return self.mine }
}

fn sink(@move x: i32) -> i32 { return x }

fn main() -> i32 {
    var d = D()
    var b = poke_base(&d)          // C++ writes d.mine = 42 through pick(): 42 + 42
    if d.mine != 42 {
        return 1
    }

    d.pick() = 5                   // Kairo writes through its own override
    d.pick() += 1                  // 6
    var *p = &d.pick()             // the address of d.mine
    (*p) += 10                     // 16
    var t = d.pick()               // a copy: typeof(d.pick()) is i32
    t = 1000
    var q: typeof(d.pick()) = 0    // i32, not a reference
    var c = d.peek()               // 16
    var m = sink(d.take())         // the xvalue binds @move: 16
    // 84 + 16 + 16 + 16 = 132
    return b + d.mine + c + m
}

// --- lit wiring -----------------------------------------------------------
// Each override returns the place itself: C++ sees `int&` / `const int&` /
// `int&&`, the body's `return self.mine` binds it (a static_cast for
// `int&&`), and writes through the result, from C++ or Kairo, land in
// d.mine. Red on a compiler without `ffi::ref` (S053E at the return type).
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: SEMA fid {{[0-9]+}}: {{.*}}ffi_ref_return_override.k =====
// SEMA: -- inferred decls --
// SEMA-DAG: p : *i32{{$}}
// SEMA-DAG: t : i32{{$}}
// SEMA-DAG: c : i32{{$}}
// RUN: { %kairo %s --print-ir -o /dev/null 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR: virtual signed int & pick() noexcept override;
// IR: virtual const signed int & peek() const noexcept override;
// IR: virtual signed int && take() noexcept override;
// IR: signed int & D::pick() noexcept {
// IR-NEXT: return this->mine;
// IR: const signed int & D::peek() const noexcept {
// IR-NEXT: return this->mine;
// IR: signed int && D::take() noexcept {
// IR-NEXT: return static_cast<signed int &&>(this->mine);
// IR: signed int q = 0;
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 132
