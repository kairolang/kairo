// RUN: { %kairo %S/first.k %S/zero.k %s -I %S --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s --allow-empty
//
// The base of a nested class template's instance (`Owner::Iter<int>`
// over `adaptor_base<Iter<int>, int**>`) was imported from first.k's header
// set; spelling it in this TU's set needs the nested template re-found there,
// and TypeExport::_refind only walked namespaces. The base stayed unfilled, its
// hidden-friend `==` was never declared, and the range-for's desugared
// `==` found no overload (SC063E).
// CHECK-NOT: error

ffi "c++" import "iter.h"
ffi "c++" import "other.h"
import first::*
import zero::*

fn walk(o: unsafe *xr::Owner) -> bool {
    for sp in o->specs() { var q = sp; }
    return first_walk(o)
}
