// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// An instance of an imported class template. `make_box()` returns the
// concrete `Box<int>`, whose table M2 never fills -- clang owns that
// instantiation (MemberLookup::filled_by_clang) -- so the first member
// lookup has ForeignInstantiate fill it from clang: `.value` and `.get()`
// are found in the instance's own table, already i32. (Were the fill to
// fail, lookup would walk the pattern and substitute `T`; the answer is the
// same, which is why this test pins the types, not the path.)

ffi "c++" import "template.h"

fn use_template() -> i32 {
    var b = make_box()
    var v = b.value
    return b.get() + v
}

// DIAG-NOT: error

// SEMA:      use     make_box  {{.*}} -> fn make_box @ 11:1  [import overlay]
// SEMA:      member  .value  {{.*}} -> field value @ 7:5  [member of Box]
// SEMA:      member  .get  {{.*}} -> fn get @ 8:5  [member of Box]
// SEMA:      0 unknown, 0 errored
// SEMA:      -- inferred decls --
// SEMA-NEXT: b : Box<i32>
// SEMA-NEXT: v : i32
