// The GH#87 rule reads an imported template instance over a move-only
// element as MOVE only when it HOLDS such a value: a `value_type` member
// type, a field or a base that cannot be copied (ClassLifecycle::
// _imported_elements). A template that only points at its argument --
// `std::shared_ptr<Mv>`, `std::weak_ptr<Mv>` -- copies a handle and stays
// COPY, so a second use after a transfer is no use after move. A vector
// of Mv still holds one.

ffi "c++" import "memory"
ffi "c++" import "vector"

class Mv {
    pub var n: i32 = 0
    fn Mv(self, n: i32) { self.n = n }
    @move fn Mv(self, other: Self) { self.n = other.n }
}

fn shared() -> i64 {
    var p: cxx::std::shared_ptr<Mv>
    var q = p                            // a copy of the handle
    var w: cxx::std::weak_ptr<Mv>
    var v = w
    return p.use_count() + q.use_count() + w.use_count()
}

fn owned() -> usize {
    var words: cxx::std::vector<Mv>
    var all = words
    return words.size()
// DIAG: imported_handle_copy.k:[[@LINE-1]]:12: error [SC052E]: 'words' is used after being moved
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
