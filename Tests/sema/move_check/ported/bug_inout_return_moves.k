// `return v` of an `@inout` parameter moves the argument out of the caller's
// variable, as `self.slot = v` does (ownership.mdx, Moved-From State: a
// function that returns while a part of an `@inout` parameter is moved-from
// leaves it moved-from in the caller; transfer semantics: returning a MOVE
// value moves it). The compiler does not see the move through `return v`, so
// the read after each call below is accepted.

class Task {
    pub var id: i32 = 0
    fn Task(self, id: i32) { self.id = id }
    @move fn Task(self, other: Self) { self.id = other.id; other.id = 0 }
}

fn take_whole(@inout v: Task) -> Task { return v }
fn take_nullable(@inout v: Task) -> Task? { return v }

fn caller_whole() -> i32 {
    var t = Task(1)
    var r = take_whole(&t)
    return t.id + r.id //! SC052E
}

fn caller_nullable() -> i32 {
    var t = Task(1)
    var r = take_nullable(&t)
    return t.id //! SC052E
}

// XFAIL: *

// XFAIL: *
// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: bug_inout_return_moves.k:20:{{[0-9]+}}: error [SC052E]:
// CHECK: bug_inout_return_moves.k:26:{{[0-9]+}}: error [SC052E]:
