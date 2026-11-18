// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9
//
// The implicit object parameter ranks on its whole cv, not only const
// ([over.ics.rank]/3.2.6): a plain object prefers `get() const` to `get()
// const volatile` and `put()` to `put() volatile`, as clang does. Ranking
// saw only const, so every such pair tied (SC064E), which made
// std::atomic's store / load / fetch_add unusable. The tie that C++ keeps
// (`const` against `volatile`) is receiver_cv_rank_tie.k.

ffi "c++" import "receiver_cv_rank.h"
ffi "c++" import "atomic"

fn atom() -> u64 {
    var a: cxx::std::#atomic<u64>
    a.store(5, cxx::std::memory_order_relaxed)
    a.fetch_add(1, cxx::std::memory_order_relaxed)
    return a.load(cxx::std::memory_order_acquire)
}

fn main() -> i32 {
    var c: Cell
    // 1 + 3 = 4, plus the atomic's 6, minus 1
    return c.get() + c.put(0) + (atom() as i32) - 1
}

// DIAG-NOT: error
