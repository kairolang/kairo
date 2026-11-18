// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// The explicit-qualifier rule (R049) says a member is NOT in unqualified
// scope. So a bare name that matches a member must keep looking outward: a
// method `ext_open` calling the imported C `ext_open` means the C function.
// R049 is only the helpful diagnostic when NOTHING outside answers.

ffi "c++" import "member_shadows_outer.h"

class File {
    var fd: i32 = 0

    fn ext_open(self, p: *u8) -> bool {
        // Bare: the imported free function, not this method.
        return ext_open(p) >= 0
    }

    fn ext_close(self) {
        ext_close(self.fd)
    }

    fn only_member(self) -> i32 { return 1 }

    static fn st_open(p: *u8) -> i32 { return 0 }

    // A static method is a member too: the bare name still reaches the C one.
    static fn st_caller(p: *u8) -> i32 { return ext_open(p) }

    fn bad(self) -> i32 {
        return only_member()   // nothing outside: still R049
    }
}
// CHECK-NOT: error [R049E]: use of method 'ext_open'
// CHECK-NOT: error [R049E]: use of method 'ext_close'
// CHECK: error [R049E]: use of method 'only_member' requires an explicit qualifier
// CHECK: fix-it:{{.*}}:"self."
