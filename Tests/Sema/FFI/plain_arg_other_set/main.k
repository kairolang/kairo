// RUN: { %kairo %S/first.k %S/second.k %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// `vector` is first.k's set's, which never includes item.h, and
// `cq::Item` is second.k's set's. An argument that is a plain record of a
// THIRD set had no spelling in either, so the instance never filled and
// `size` / `push_back` were "no member named" (R025E). The record is now
// re-found by its qualified path in the set doing the fill.
// CHECK-NOT: error

ffi "c++" import "vector"
ffi "c++" import "item.h"

class Q {
    var items: cxx::std::vector<cq::Item>

    fn touch(self, n: usize) -> usize {
        self.items.resize(n)
        return self.items.size()
    }
}
