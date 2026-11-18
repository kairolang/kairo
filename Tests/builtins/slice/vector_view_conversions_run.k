// A vector converts to a slice of itself and stays live: `bump(v)` and
// `var w: [i32;] = v` borrow it (it is not moved), a `[const i32;]` view
// binds to a `const` parameter, `.data()` is found through the one-hop
// lookup on the vector and on the view, and `.size()` is callable directly on
// a range subscript.

fn bump(s: [i32;]) { s[0] += 1 }

fn total(const s: [const i32;]) -> i64 {
    var t: i64 = 0
    for x in s { t += x }
    return t
}

fn main() -> i32 {
    var v: [i32] = [1, 2]
    bump(v)
    var w: [i32;] = v
    bump(w)
    var d = v.data()
    var c: [const i32;] = v
    var e = c.data()
    var bad = 0
    if v[0] != 3 { bad = bad + 1 }
    if total(v) != 5 { bad = bad + 2 }
    if total(c) != 5 { bad = bad + 4 }
    var q: [i32] = [1, 2, 3, 4]
    if q[(1 as usize)..(3 as usize)].size() != 2 { bad = bad + 8 }
    return bad
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: newlib
// RUN: rm -rf %t.d %t.e
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.e
// RUN: %t.o2.exe
