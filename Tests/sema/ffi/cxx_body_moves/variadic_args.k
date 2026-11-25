// A pointer to the object passed through a C `...` argument reaches a body
// that reads it back with `va_arg` as any type it names, so the walk cannot
// say what that body does with it: the call is not known. A pointer to
// const is not followed, as for a declared parameter, and a call that does
// not pass the object on is read as usual. A C library variadic with no
// visible body is assumed not to move it, as for a declared parameter.

ffi "c++" import "inputs/variadic.h"

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

fn by_pointer() -> i32 {
    var h = Res(1)
    pass_va(unsafe &h)
    return h.id
}

fn by_address() -> i32 {
    var h = Res(2)
    pass_va_ref(&h)
    return h.id
}

fn const_pointer() -> i32 {
    var h = Res(3)
    pass_va_const(unsafe &h)
    return h.id
}

fn not_passed() -> i32 {
    var h = Res(4)
    pass_va_none(unsafe &h)
    return h.id
}

fn library() -> i32 {
    var h = Res(5)
    pass_va_lib(unsafe &h)
    return h.id
}

fn main() -> i32 {
    return by_pointer() + by_address() + const_pointer() + not_passed() + library()
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only -fstrict-cxx-moves 2>&1 || true; } | %FileCheck %s --check-prefix=STRICT
// RUN: { %kairo %s --type-check-only -fno-strict-cxx-moves --print-unchecked-assumptions 2>&1 || true; } | %FileCheck %s --check-prefix=OFF

// STRICT: variadic_args.k:25:12: error [SC052E]: 'h' is used after being moved
// STRICT: variadic_args.k:24:5: note {{.*}}: 'h' was moved here, by the call to 'pass_va'
// STRICT: variadic_args.k:31:12: error [SC052E]: 'h' is used after being moved
// STRICT: variadic_args.k:30:5: note {{.*}}: 'h' was moved here, by the call to 'pass_va_ref'
// STRICT-NOT: error

// OFF: variadic_args.k:24:5: unchecked assumption: 'pass_va' is assumed not to move out of 'h': it passes it to 'steal_va' through a C `...` argument
// OFF: variadic_args.k:30:5: unchecked assumption: 'pass_va_ref' is assumed not to move out of 'h': it passes it to 'steal_va' through a C `...` argument
// OFF: variadic_args.k:48:5: unchecked assumption: 'pass_va_lib' passes 'h' to 'swprintf', a C library function whose body is not visible: assumed not to move out of it
// OFF-NOT: unchecked assumption
// OFF-NOT: error
