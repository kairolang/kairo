// RUN: { %kairo %s --type-check-only --print-unchecked-assumptions -fno-strict-cxx-moves 2>&1 || true; } | %FileCheck %s
//
// A pointer to the object handed on by `T*&` / `T* const&` still reaches
// the object: a body that moves `*q` moves it, and a virtual call or a call
// through a function pointer given it cannot be read. A call through a
// pointer to member function on the object is not known either.

ffi "c++" import "Inputs/walk.h"

class Res {
    pub var id: i32 = 0
    fn Res(self, id: i32) {
        self.id = id
    }

    @move fn Res(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
}

fn direct() -> i32 {
    var h = Res(1)
    by_ptr_ref(unsafe &h)
    return h.id
}

fn through_virtual(v: unsafe *PtrViewer<Res>) -> i32 {
    var h = Res(2)
    view_ptr_ref(v, unsafe &h)
    return h.id
}

fn through_pointer() -> i32 {
    var h = Res(3)
    via_ptr_ref_fp(unsafe &h)
    return h.id
}

fn member_fn() -> i32 {
    var b = Box2<Res>()
    member_fn_ptr(&b)
    return b.t.id
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// CHECK: pointer_refs.k:30:5: unchecked assumption: 'view_ptr_ref' is assumed not to move out of 'h': it passes it to 'PtrViewer<{{.*}}Res>::poke_ptr', a virtual call
// CHECK: pointer_refs.k:36:5: unchecked assumption: 'via_ptr_ref_fp' is assumed not to move out of 'h': 'via_ptr_ref_fp' passes it to a call through a pointer
// CHECK: pointer_refs.k:42:5: unchecked assumption: 'member_fn_ptr' is assumed not to move out of 'b': 'member_fn_ptr' passes it to a call through a pointer
// CHECK-NOT: unchecked assumption
// CHECK: pointer_refs.k:25:12: error [SC052E]: 'h' is used after being moved
// CHECK: pointer_refs.k:24:5: note {{.*}}: 'h' was moved here, by the call to 'by_ptr_ref'
// CHECK-NOT: error
