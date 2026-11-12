// Copies of a move-only value that only clang rejected (CL001E). Each
// is SC182E:
// - a field of a `const` parameter (a const place cannot be moved from);
// - an element of a C++ container reached through its `T&` (`cv[0]`):
//   MoveCheck never moves out of a reference, so the transfer is a copy;
// - a plain `for` binder over a container or a generator of them: the
//   binder is a copy of each element (`*x` binds its address instead).
// - `v[0] = v[1]` of a builtin vector: it would move one element out into
//   another, and whether a move out of `x[i]` is allowed is not decided;
//   clang rejected it, and it is refused rather than becoming a silent move.
// `push_back` of an lvalue was on the list too; it compiles (the `T&&`
// overload moves), so nothing is checked for it here.

ffi "c++" import "vector"

class Tok {
    pub var id: i32 = 0
    fn Tok(self) { self.id = 3 }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

class R {
    pub var s: Tok
    fn R(self) { self.s = Tok() }
}

fn peek(const r: R) -> i32 {
    var x = r.s
    return x.id
}

fn gen(n: i32) -> yield Tok {
    for var i = 0; i < n; ++i {
        yield Tok()
    }
}

fn main() -> i32 {
    var cv: cxx::std::vector<Tok>
    cv.push_back(Tok())
    cv.push_back(Tok())
    var x = cv[0]
    cv[0] = cv[1]

    var v: [Tok]
    v.push(Tok())
    var s = 0
    for t in v {
        s += t.id
    }

    for t: Tok in cv {
        s += t.id
    }

    for t in gen(2) {
        s += t.id
    }

    // The address binder copies nothing.
    for *t in v {
        s += t->id
    }

    v.push(Tok())
    v[0] = v[1]
    return s
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: move_only_copy_shapes.k:28:13: error [SC182E]: cannot copy a value of type 'Tok': it declares a move constructor and no copy constructor
// CHECK: move_only_copy_shapes.k:28:13: note [I900N]: 'r.s' is const, so the transfer into 'x' cannot move it, and moving is the only transfer its type has
// CHECK: move_only_copy_shapes.k:42:13: error [SC182E]: cannot copy a value of type 'Tok'
// CHECK: move_only_copy_shapes.k:42:13: note [I900N]: 'cv[0]' is a reference into storage this code does not own (a C++ 'T&'), which is never moved from, so the transfer into 'x' copies it
// CHECK: move_only_copy_shapes.k:43:13: error [SC182E]: cannot copy a value of type 'Tok'
// CHECK: move_only_copy_shapes.k:43:13: note [I900N]: 'cv[1]' is a reference into storage
// CHECK: move_only_copy_shapes.k:48:9: error [SC182E]: cannot copy a value of type 'Tok'
// CHECK: move_only_copy_shapes.k:48:9: note [I900N]: the loop binder 't' is a copy of each element; bind '*t' for the element's address instead
// CHECK: move_only_copy_shapes.k:52:9: error [SC182E]: cannot copy a value of type 'Tok'
// CHECK: move_only_copy_shapes.k:56:9: error [SC182E]: cannot copy a value of type 'Tok'
// CHECK: move_only_copy_shapes.k:66:12: error [SC182E]: cannot copy a value of type 'Tok'
// CHECK: move_only_copy_shapes.k:66:12: note [I900N]: 'v[1]' is an element of a container, and moving an element out into another element is not supported; swap them, or move through a local
