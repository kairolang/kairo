// A C++ aggregate template whose transfers are all `= default`
// (std::pair) holding a move-only Kairo class is MOVE, not COPY with its copy
// folded to "not copyable" (which would make `var p = o` SC182E even as a move). C++
// defines such a defaulted copy as deleted and keeps the defaulted move: it
// is MOVE. A move works, a second use is SC052E, and copying a const
// one is SC182E.

ffi "c++" import "utility"

class Mv {
    pub var id: i32 = 0
    fn Mv(self) { self.id = 3 }
    @move fn Mv(self, other: Self) { self.id = other.id; other.id = 0 }
}

fn copy_const(const o: cxx::std::pair<Mv, i32>) -> i32 {
    var p = o
    return 0
}

fn main() -> i32 {
    var o: cxx::std::pair<Mv, i32>
    var p = o
    var q = o
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: pair_move_only.k:17:13: error [SC182E]: cannot copy a value of type 'pair<Mv, i32>': its field 'first' is not copyable
// CHECK: pair_move_only.k:17:13: note [I900N]: 'o' is const, so the transfer into 'p' cannot move it, and moving is the only transfer its type has
// CHECK: pair_move_only.k:24:13: error [SC052E]: 'o' is used after being moved
// CHECK: pair_move_only.k:23:13: note [I900N]: 'o' was moved here, into 'p'
