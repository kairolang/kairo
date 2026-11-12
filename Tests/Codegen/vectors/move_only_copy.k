// `[MoveOnly]` is neither copied nor moved: Vector's @copy constructor is
// constrained on T being copyable, and a class declares one transfer
// constructor (SC057E), so no move exists to fall back on. Build one in
// place and pass it by reference (vectors/lifecycle.k). Copying one, or
// returning a named one (which needs a transfer even where clang would
// elide it), is refused by Kairo (SC182E): MoveCheck evaluates the
// instance's @copy `requires`, though ClassLifecycle still reads a declared
// @copy as COPY whatever T is. Both runs stop at Sema with the two lines;
// clang (CL001E at both) does not see them.

class Mv {
    var v: i32
    fn Mv(self, v: i32) { self.v = v }
    @move fn Mv(self, other: Self) = default
}

fn make() -> [Mv] {
    var a: [Mv]
    a.emplace_back(1)
    return a
}

fn main() -> i32 {
    var a: [Mv]
    a.emplace_back(1)
    var b = a
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG: move_only_copy.k:20:12: error [SC182E]: cannot copy a value of type '[Mv]': copying it copies each 'Mv', and 'Mv' cannot be copied
// DIAG: move_only_copy.k:26:13: error [SC182E]: cannot copy a value of type '[Mv]': copying it copies each 'Mv', and 'Mv' cannot be copied
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: move_only_copy.k:20:12: error [SC182E]: cannot copy a value of type '[Mv]'
// CXX: move_only_copy.k:26:13: error [SC182E]: cannot copy a value of type '[Mv]'
// CXX-NOT: CL001E
