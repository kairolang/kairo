// std::move(x) leaves x moved-from as passing it to a `@move` parameter does:
// a later use is SC052E and assigning x again makes it usable. That holds for
// a local, a parameter, a field of self, a field and the pointee reached
// through a pointer, and an element (which leaves the whole container
// moved-from). A COPY class and a primitive are moved-from too, since a
// generic `@move` parameter consumes its argument whatever the type.
// `import std::move` makes the bare spelling `move(x)` the same function.

import std
import std::move

class Res {
    pub var h: i32 = 0
    fn Res(self) {
        self.h = 1
    }

    @move fn Res(self, other: Self) {
        self.h  = other.h
        other.h = 0
    }
}

class Cp {
    pub var h: i32 = 0
    fn Cp(self) {
        self.h = 2
    }

    @copy fn Cp(self, const other: Self) {
        self.h = other.h
    }
}

class Pair {
    pub var a: Res
    pub var b: Res

    fn take_a(self) -> i32 {
        var x  = std::move(self.a)
        var ok = self.b.h
        return self.a.h
        // DIAG: move_tracking.k:[[@LINE-1]]:16: error [SC052E]: 'self.a' is used after being moved
        // DIAG: move_tracking.k:[[@LINE-4]]:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: 'self.a' was moved here, into a '@move' parameter
    }
}

fn local() -> i32 {
    var a = Res()
    var b = std::move(a)
    return a.h
    // DIAG: move_tracking.k:[[@LINE-1]]:12: error [SC052E]: 'a' is used after being moved
    // DIAG: move_tracking.k:[[@LINE-3]]:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: 'a' was moved here, into a '@move' parameter
}

fn local_reassigned() -> i32 {
    var a = Res()
    var b = std::move(a)
    a = Res()
    return a.h + b.h
}

fn bare_spelling() -> i32 {
    var a = Res()
    var b = move(a)
    return a.h
    // DIAG: move_tracking.k:[[@LINE-1]]:12: error [SC052E]: 'a' is used after being moved
    // DIAG: move_tracking.k:[[@LINE-3]]:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: 'a' was moved here, into a '@move' parameter
}

fn param(r: Res) -> i32 {
    var b = std::move(r)
    return r.h
    // DIAG: move_tracking.k:[[@LINE-1]]:12: error [SC052E]: 'r' is used after being moved
    // DIAG: move_tracking.k:[[@LINE-3]]:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: 'r' was moved here, into a '@move' parameter
}

fn through_pointer(q: *Pair) -> i32 {
    var y  = std::move(q->a)
    var ok = q->b.h
    return q->a.h
    // DIAG: move_tracking.k:[[@LINE-1]]:12: error [SC052E]: 'q->a' is used after being moved
    // DIAG: move_tracking.k:[[@LINE-4]]:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: 'q->a' was moved here, into a '@move' parameter
}

fn through_pointer_reassigned(q: *Pair) -> i32 {
    var y = std::move(q->a)
    q->a = Res()
    return q->a.h
}

fn pointee(q: *Res) -> i32 {
    var y = std::move(*q)
    return q->h
    // DIAG: move_tracking.k:[[@LINE-1]]:12: error [SC052E]: '*q' is used after being moved
    // DIAG: move_tracking.k:[[@LINE-3]]:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: '*q' was moved here, into a '@move' parameter
}

fn array_element() -> i32 {
    var arr: [Res; 2]
    var e             = std::move(arr[0])
    return arr[1].h
    // DIAG: move_tracking.k:[[@LINE-1]]:12: error [SC052E]: 'arr' is used after 'arr[0]' was moved out of it
    // DIAG: move_tracking.k:[[@LINE-3]]:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: 'arr[0]' was moved here, into a '@move' parameter
}

fn vector_element() -> usize {
    var v: [Res] = []
    var e        = std::move(v[0])
    return v.size()
    // DIAG: move_tracking.k:[[@LINE-1]]:12: error [SC052E]: 'v' is used after 'v[0]' was moved out of it
    // DIAG: move_tracking.k:[[@LINE-3]]:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: 'v[0]' was moved here, into a '@move' parameter
}

fn copy_class() -> i32 {
    var c = Cp()
    var d = std::move(c)
    return c.h
    // DIAG: move_tracking.k:[[@LINE-1]]:12: error [SC052E]: 'c' is used after being moved
    // DIAG: move_tracking.k:[[@LINE-3]]:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: 'c' was moved here, into a '@move' parameter
}

fn primitive() -> i32 {
    var i: i32 = 3
    var j      = std::move(i)
    return i
    // DIAG: move_tracking.k:[[@LINE-1]]:12: error [SC052E]: 'i' is used after being moved
    // DIAG: move_tracking.k:[[@LINE-3]]:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: 'i' was moved here, into a '@move' parameter
}

fn primitive_reassigned() -> i32 {
    var i: i32 = 3
    var j      = std::move(i)
    i = 4
    return i + j
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
