// RUN: { %kairo %S/first.k %s -I %S --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// First.k demands the fill of unique_ptr<Thing> first, from a set
// that cannot spell Thing (nor can <memory>'s primary set). That failure
// was sticky, so this TU -- whose own set sees thing.h -- found the
// instance unfilled too: `pointer` stayed '<ffi type>' and the constructor
// taking a raw pointer had no overload (SC063E).
// CHECK-NOT: error

ffi "c++" import "memory"
ffi "c++" import "thing.h"
import first::*

fn adopt(raw: unsafe *xr::Thing) -> bool {
    var p = cxx::std::unique_ptr<xr::Thing>(raw)
    return (p.get() == raw) && peek()
}
