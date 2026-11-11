// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
//
// A MOVE-category value (here a class owning a unique_ptr) is an xvalue at a
// call only because passing it by value moves it. A plain C++ `T&` parameter
// borrows instead (`@inout`), so the variable binds as the lvalue it is, and
// a derived class binds the base subobject: `ci->ExecuteAction(act)` with
// `act: clang::EmitObjAction` is not SC063E "cannot convert argument of type
// 'EmitObjAction' to parameter 'Act' of type 'FrontendAction&'".

// DIAG-NOT: error

ffi "c++" import "move_type_to_lvalue_ref.h"

fn main() -> i32 {
    var act = ns::Leaf()
    var h = ns::Host()
    // Leaf::id() is 3 through the base reference both times.
    return ns::take(&act) + h.run(&act)
}
