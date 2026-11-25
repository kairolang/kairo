// cxx::std::move(x[i]) hands an element off as a `@move` parameter does:
// the element is the place form of the container's split subscript, and the
// container is moved-from until it is assigned again. A COPY element is
// copied, and its container stays readable.

ffi "c++" import "utility"

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) {
        self.id = id
    }

    @move fn Tok(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
}

// The place form of a map's subscript makes a missing value.
extend Tok impl Default {
    static fn make_default() -> Tok = Tok(0)
}

fn eat(t: Tok) -> i32 {
    return t.id
}

fn into_local() -> i32 {
    var v:    [Tok] = [Tok(1), Tok(2)]
    var first       = cxx::std::move(v[0])
    return v[1].id + first.id
    // DIAG: cxx_move_element.k:[[@LINE-1]]:12: error [SC052E]: 'v' is used after 'v[0]' was moved out of it
    // DIAG: cxx_move_element.k:[[@LINE-3]]:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: 'v[0]' was moved here, into a '@move' parameter
}

fn into_argument() -> i32 {
    var v: [Tok] = [Tok(1), Tok(2)]
    var r        = eat(cxx::std::move(v[0]))
    return (v.size() as i32) + r
    // DIAG: cxx_move_element.k:[[@LINE-1]]:13: error [SC052E]: 'v' is used after 'v[0]' was moved out of it
    // DIAG: cxx_move_element.k:[[@LINE-3]]:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: 'v[0]' was moved here, into a '@move' parameter
}

fn map_value() -> i32 {
    var m: {i32: Tok} = {}
    m[1] = Tok(1)
    var t = cxx::std::move(m[1])
    return (m.size() as i32) + t.id
    // DIAG: cxx_move_element.k:[[@LINE-1]]:13: error [SC052E]: 'm' is used after 'm[1]' was moved out of it
    // DIAG: cxx_move_element.k:[[@LINE-3]]:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: 'm[1]' was moved here, into a '@move' parameter
}

fn reassigned() -> i32 {
    var v:    [Tok] = [Tok(1), Tok(2)]
    var first       = cxx::std::move(v[0])
    v = [Tok(3)]
    return v[0].id + first.id
}

fn copy_element() -> i32 {
    var v:    [i32] = [1, 2]
    var first       = cxx::std::move(v[0])
    return v[1] + first
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
