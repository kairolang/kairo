// Strict C++ moves are the default: a C++ call whose body cannot be
// inspected leaves its MOVE argument moved-from, and the note names the
// flag that makes it borrow. A call into the C++ standard library borrows
// under the default too, on an assumption the build lists, so reading a
// stream line by line compiles. -fno-strict-cxx-moves borrows every such
// call.

ffi "c++" import "inputs/moves.h"
ffi "c++" import "sstream"
ffi "c++" import "string"

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

fn lines_of() -> i32 {
    var f     = cxx::std::istringstream(cxx::std::string("ab\ncd\n"))
    var line  = cxx::std::string()
    var lines = 0
    while cxx::std::getline(&f, &line) as bool {
        lines += 1
    }

    return lines
}

fn opaque_call() -> i32 {
    var h = Res(7)
    opaque(&h)
    return h.id
}

fn main() -> i32 {
    return lines_of() + opaque_call()
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// RUN: { %kairo %s --type-check-only --print-unchecked-assumptions 2>/dev/null || true; } | %FileCheck %s --check-prefix=LIST
// RUN: { %kairo %s --type-check-only -fno-strict-cxx-moves 2>&1 || true; } | %FileCheck %s --check-prefix=OFF --allow-empty
// RUN: { %kairo %s --type-check-only -fno-strict-cxx-moves --print-unchecked-assumptions 2>/dev/null || true; } | %FileCheck %s --check-prefix=OFFLIST

// CHECK-NOT: strict_default_std.k:{{[1-3][0-9]}}:{{.*}}error
// CHECK: strict_default_std.k:38:12: error [SC052E]: 'h' is used after being moved
// CHECK: strict_default_std.k:37:5: note {{.*}}: 'h' was moved here, by the call to 'opaque', whose body cannot be inspected and is taken to move it under -fstrict-cxx-moves
// CHECK: moves.h:{{[0-9]+}}:{{[0-9]+}}: note {{.*}}: not inspected: its body is not visible; with -fno-strict-cxx-moves the call borrows it, on an unchecked assumption
// CHECK-NOT: error

// LIST: strict_default_std.k:28:11: unchecked assumption: 'getline' is a C++ standard library function whose body is not visible: assumed not to move out of 'f'
// LIST-NOT: unchecked assumption

// OFF-NOT: error

// OFFLIST: strict_default_std.k:28:11: unchecked assumption: 'getline' is a C++ standard library function whose body is not visible: assumed not to move out of 'f'
// OFFLIST: strict_default_std.k:37:5: unchecked assumption: 'opaque' is assumed not to move out of 'h': its body is not visible
// OFFLIST-NOT: unchecked assumption
