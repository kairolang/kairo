// A C++ call whose body cannot be inspected is taken at its worst under
// -fstrict-cxx-moves, except where what cannot be inspected is the
// toolchain's own standard library: such a call borrows, on an assumption
// the build lists under either setting. A header that only looks like a
// system one (`#pragma GCC system_header`, a declaration into namespace
// std) is not the library, and a std function whose body is visible and
// moves is still a move.

ffi "c++" import "inputs/stdlib_calls.h"
ffi "c++" import "inputs/third_party.h"
ffi "c++" import "sstream"
ffi "c++" import "string"
ffi "c++" import "utility"

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

fn getline_loop() -> i32 {
    var f     = cxx::std::istringstream(cxx::std::string("ab\ncd\n"))
    var line  = cxx::std::string()
    var lines = 0
    while cxx::std::getline(&f, &line) as bool {
        lines += 1
    }

    return lines
}

fn through_user_header() -> i32 {
    var f = cxx::std::istringstream(cxx::std::string("ab\n"))
    read_line(&f)
    read_line(&f)
    return 0
}

fn std_then_opaque() -> i32 {
    var f = cxx::std::istringstream(cxx::std::string("ab\n"))
    read_and_hide(&f)
    read_line(&f)
    return 0
}

fn third_party() -> i32 {
    var h = Res(7)
    tp::consume(&h)
    return h.id
}

fn declared_into_std() -> i32 {
    var h = Res(7)
    cxx::std::not_really_std(&h)
    return h.id
}

fn visible_std_move() -> i32 {
    var a = Res(1)
    var b = Res(2)
    cxx::std::swap(&a, &b)
    return a.id
}

fn main() -> i32 {
    return getline_loop() + through_user_header() + std_then_opaque() + third_party() +
        declared_into_std() + visible_std_move()
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only -fstrict-cxx-moves 2>&1 || true; } | %FileCheck %s --check-prefix=STRICT
// RUN: { %kairo %s --type-check-only -fstrict-cxx-moves --print-unchecked-assumptions 2>/dev/null || true; } | %FileCheck %s --check-prefix=LIST
// RUN: { %kairo %s --type-check-only -fno-strict-cxx-moves 2>&1 || true; } | %FileCheck %s --check-prefix=OFF
// RUN: { %kairo %s --type-check-only -fno-strict-cxx-moves --print-unchecked-assumptions 2>/dev/null || true; } | %FileCheck %s --check-prefix=OFFLIST

// The std calls borrow; the call that also reaches 'hidden' does not.
// STRICT-NOT: std_library_assumed.k:{{3[0-9]|4[0-7]}}:{{.*}}error
// STRICT: std_library_assumed.k:48:16: error [SC052E]: 'f' is used after being moved
// STRICT: std_library_assumed.k:47:5: note {{.*}}: 'f' was moved here, by the call to 'read_and_hide', whose body cannot be inspected and is taken to move it under -fstrict-cxx-moves
// STRICT: stdlib_calls.h:18:5: note {{.*}}: not inspected: it passes it to 'hidden', whose body is not visible; with -fno-strict-cxx-moves the call borrows it, on an unchecked assumption
// A system-header-looking third-party header, and one declaring into std.
// STRICT: std_library_assumed.k:55:12: error [SC052E]: 'h' is used after being moved
// STRICT: std_library_assumed.k:54:5: note {{.*}}: 'h' was moved here, by the call to 'consume', whose body cannot be inspected
// STRICT: third_party.h:{{[0-9]+}}:{{[0-9]+}}: note {{.*}}: not inspected: its body is not visible; with -fno-strict-cxx-moves the call borrows it
// STRICT: std_library_assumed.k:61:12: error [SC052E]: 'h' is used after being moved
// STRICT: std_library_assumed.k:60:5: note {{.*}}: 'h' was moved here, by the call to 'not_really_std', whose body cannot be inspected
// STRICT: third_party.h:{{[0-9]+}}:{{[0-9]+}}: note {{.*}}: not inspected: its body is not visible; with -fno-strict-cxx-moves the call borrows it
// std::swap's body is visible, and moves.
// STRICT: std_library_assumed.k:68:12: error [SC052E]: 'a' is used after being moved
// STRICT: std_library_assumed.k:67:5: note {{.*}}: 'a' was moved here, by the call to 'swap'
// STRICT: swap.h:{{[0-9]+}}:{{[0-9]+}}: note {{.*}}: 'std::swap' moves it here
// STRICT-NOT: error

// LIST: std_library_assumed.k:31:11: unchecked assumption: 'getline' is a C++ standard library function whose body is not visible: assumed not to move out of 'f'
// LIST: std_library_assumed.k:40:5: unchecked assumption: 'read_line' passes 'f' to 'std::getline', a C++ standard library function whose body is not visible: assumed not to move out of it
// LIST: std_library_assumed.k:41:5: unchecked assumption: 'read_line' passes 'f' to 'std::getline'
// LIST-NOT: std_library_assumed.k:47:{{.*}}unchecked assumption
// LIST: std_library_assumed.k:48:5: unchecked assumption: 'read_line' passes 'f' to 'std::getline'
// LIST-NOT: unchecked assumption

// OFF-NOT: std_library_assumed.k:{{[1-5][0-9]}}:{{.*}}error
// OFF: std_library_assumed.k:68:12: error [SC052E]: 'a' is used after being moved
// OFF-NOT: error

// OFFLIST: std_library_assumed.k:31:11: unchecked assumption: 'getline' is a C++ standard library function whose body is not visible: assumed not to move out of 'f'
// OFFLIST: std_library_assumed.k:40:5: unchecked assumption: 'read_line' passes 'f' to 'std::getline'
// OFFLIST: std_library_assumed.k:41:5: unchecked assumption: 'read_line' passes 'f' to 'std::getline'
// OFFLIST: std_library_assumed.k:47:5: unchecked assumption: 'read_and_hide' is assumed not to move out of 'f': it passes it to 'hidden', whose body is not visible
// OFFLIST: std_library_assumed.k:48:5: unchecked assumption: 'read_line' passes 'f' to 'std::getline'
// OFFLIST: std_library_assumed.k:54:5: unchecked assumption: 'consume' is assumed not to move out of 'h': its body is not visible
// OFFLIST: std_library_assumed.k:60:5: unchecked assumption: 'not_really_std' is assumed not to move out of 'h': its body is not visible
// OFFLIST-NOT: unchecked assumption
