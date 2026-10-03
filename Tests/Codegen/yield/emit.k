// The generator's body as C++: `yield` is `co_yield`, a bare `return` is
// `co_return`, and a generator with no `yield` still gets a coroutine keyword.
//
// Print only: it cannot link until the shim tickets land (noexcept, the
// `::std` placement, the coroutine_traits specialization). A yield whose
// operand converts to the element would also stop in clang until
// YieldPromise gains its `yield_value(@move v: T)` overload; every operand
// here is already the element type.

fn upto(n: i32) -> yield i32 {
    for var i: i32 = 0; i < n; ++i {
        yield i
    }
}

fn early(n: i32) -> yield i32 {
    yield 1
    if n == 0 { return }
    yield 2
}

fn none() -> yield i32 { }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      upto(signed int n) {
// CXX:      co_yield(i);
// CXX:      early(signed int n) {
// CXX:      co_yield(1);
// CXX:      co_return;
// CXX:      co_yield(2);
// CXX:      none() {
// CXX-NEXT: co_return;
// CXX-NEXT: }
