// RUN: { %kairo %S/first.k %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// first.k is checked ahead of this file and its set imports <vector>
// first, so `vector` is that set's -- a set that never includes cell.h. An
// instance over a cell.h type had no spelling there and never filled:
// `size_type` stayed opaque, so `[]` / `resize` rejected a usize (SC063E,
// `__n` of type '<ffi type>') and `i < v.size()` had no operator (SC066E).
// The fill falls back to this TU's own set, which sees both headers.
// CHECK-NOT: error

ffi "c++" import "vector"
ffi "c++" import "cell.h"

class Q {
    var cells: cxx::std::vector<cq::Cell<i32, 4>>
    var plain: cxx::std::vector<cq::Plain>

    fn touch(self, n: usize) -> i32 {
        self.cells.resize(n)
        self.plain.resize(n)
        var s: i32 = 0
        for var i: usize = 0; i < self.cells.size(); ++i {
            s += self.cells[i].v[0] + self.plain[i].x
        }
        return s
    }
}
