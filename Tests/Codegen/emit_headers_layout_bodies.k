// kals' clangd bridge: under --emit-headers-layout the out-of-line
// definition of a function whose declaration holds its .k line is left
// out, so clangd's go-to-definition lands on that line. A body C++ may
// need (a consteval one here) is kept. A plain --emit-headers keeps all.
/// A counter.
pub class Counter {
    pub var n: i32

    pub fn Counter(self) = default

    /// Its count.
    pub inline fn count(const self) -> i32 { return self.n }
}

/// The first of two.
pub fn <T> first(a: T, b: T) -> T { return a }

extend i32 {
    /// Twice the value.
    pub inline fn twice(const self) -> i32 { return self * 2 }
}

/// A square, at compile time.
pub eval fn square(x: i32) -> i32 { return x * x }

/// Inline, after the class.
pub inline fn plus(a: Counter, b: i32) -> i32 { return a.count() + b }

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h --emit-headers-layout
// RUN: sed -n 12p %t.d/h/emit_headers_layout_bodies.hh | %FileCheck %s --check-prefix=L12
// RUN: sed -n 16p %t.d/h/emit_headers_layout_bodies.hh | %FileCheck %s --check-prefix=L16
// RUN: sed -n 20p %t.d/h/emit_headers_layout_bodies.hh | %FileCheck %s --check-prefix=L20
// RUN: sed -n 27p %t.d/h/emit_headers_layout_bodies.hh | %FileCheck %s --check-prefix=L27
// RUN: %FileCheck %s --check-prefix=LAY < %t.d/h/emit_headers_layout_bodies.hh
// RUN: %FileCheck %s --check-prefix=NOBODY < %t.d/h/emit_headers_layout_bodies.hh
// RUN: printf '#include "h/emit_headers_layout_bodies.hh"\nstatic_assert(emit_headers_layout_bodies::square(3) == 9);\nint f(emit_headers_layout_bodies::Counter c, int v) { return c.count() + emit_headers_layout_bodies::first(1, 2) + emit_headers_layout_bodies::__kairo_ext_i32::twice(&v) + emit_headers_layout_bodies::plus(c, 1); }\n' > %t.d/use.cc
// RUN: { %clangxx -std=c++23 -fsyntax-only -Wundefined-inline -Wundefined-internal %t.d/use.cc 2>&1 || true; } | %FileCheck %s --check-prefix=CXX --allow-empty
// RUN: %kairo %s --type-check-only --emit-headers %t.d/p
// RUN: %FileCheck %s --check-prefix=PLAIN < %t.d/p/emit_headers_layout_bodies.hh

// L12: signed int count() const noexcept;
// L16: template<class T> T first(T a, T b) noexcept;
// L20: static signed int twice(const signed int* self) noexcept;
// L27: signed int plus(::emit_headers_layout_bodies::Counter a, signed int b) noexcept;

// LAY: consteval signed int square(signed int x) noexcept {

// NOBODY-NOT: Counter::count() const noexcept {
// NOBODY-NOT: first(T a, T b) noexcept {
// NOBODY-NOT: __kairo_ext_i32::twice(const signed int* self) noexcept {
// NOBODY-NOT: plus(::emit_headers_layout_bodies::Counter a, signed int b) noexcept {

// CXX-NOT: error
// CXX-NOT: {{\.(hh|cc|prelude):[0-9]+:[0-9]+: warning}}

// PLAIN-DAG: Counter::count() const noexcept {
// PLAIN-DAG: T first(T a, T b) noexcept {
// PLAIN-DAG: __kairo_ext_i32::twice(const signed int* self) noexcept {
// PLAIN-DAG: plus(::emit_headers_layout_bodies::Counter a, signed int b) noexcept {
