// A Kairo function that hands its `@inout` argument to a C++ call
// -fstrict-cxx-moves takes at its worst leaves it moved-from, and its
// caller's error says so: the note at the caller's call names the C++ call
// that could not be inspected and the flag that makes it borrow, however
// many Kairo calls lie between. -fno-strict-cxx-moves borrows it at every
// level.

ffi "c++" import "Inputs/moves.h"

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

fn facts_of(@inout h: Res) {
    opaque(&h)
}

fn outer(@inout h: Res) {
    facts_of(&h)
}

fn one_deep() -> i32 {
    var h = Res(7)
    facts_of(&h)
    return h.id
}

fn two_deep() -> i32 {
    var h = Res(7)
    outer(&h)
    return h.id
}

fn main() -> i32 {
    return one_deep() + two_deep()
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only -fstrict-cxx-moves 2>&1 || true; } | %FileCheck %s --check-prefix=STRICT
// RUN: { %kairo %s --type-check-only -fno-strict-cxx-moves 2>&1 || true; } | %FileCheck %s --check-prefix=OFF --allow-empty
// RUN: { %kairo %s --type-check-only -fno-strict-cxx-moves --print-unchecked-assumptions 2>/dev/null || true; } | %FileCheck %s --check-prefix=OFFLIST

// STRICT-NOT: strict_cascade_note.k:2{{[0-9]}}:{{.*}}error
// STRICT: strict_cascade_note.k:33:12: error [SC052E]: 'h' is used after being moved
// STRICT: strict_cascade_note.k:32:5: note {{.*}}: 'h' was moved here, by the call to 'facts_of', which calls a C++ function that could not be inspected
// STRICT: strict_cascade_note.k:23:5: note {{.*}}: this C++ call could not be inspected and is taken to move it under -fstrict-cxx-moves; with -fno-strict-cxx-moves it borrows, on an unchecked assumption
// STRICT: strict_cascade_note.k:39:12: error [SC052E]: 'h' is used after being moved
// STRICT: strict_cascade_note.k:38:5: note {{.*}}: 'h' was moved here, by the call to 'outer', which calls a C++ function that could not be inspected
// STRICT: strict_cascade_note.k:27:5: note {{.*}}: it is moved here
// STRICT: strict_cascade_note.k:23:5: note {{.*}}: this C++ call could not be inspected and is taken to move it under -fstrict-cxx-moves; with -fno-strict-cxx-moves it borrows
// STRICT-NOT: error

// OFF-NOT: error

// OFFLIST: strict_cascade_note.k:23:5: unchecked assumption: 'opaque' is assumed not to move out of 'h': its body is not visible
// OFFLIST-NOT: unchecked assumption
