// GH#87: `std::vector<Mv>` of a move-only Mv is MOVE (ClassLifecycle::
// _imported_elements), so a transfer of it moves and a later read is a use
// after move -- reported here, not left to libc++ as a deleted copy
// constructor. A vector of a COPY element stays COPY.

ffi "c++" import "vector"

class Mv {
    pub var n: i32 = 0
    fn Mv(self, n: i32) { self.n = n }
    @move fn Mv(self, other: Self) { self.n = other.n }
}

fn moved() -> usize {
    var words: cxx::std::vector<Mv>
    var all = words
    return words.size()
// DIAG: imported_container_move.k:[[@LINE-1]]:12: error [SC052E]: 'words' is used after being moved
}

fn copied() -> usize {
    var ints: cxx::std::vector<i32>
    var copy = ints                      // a copy: nothing to report
    return ints.size() + copy.size()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
