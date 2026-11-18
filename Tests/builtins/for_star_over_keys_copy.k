// `keys()` yields `*const K`. `for *k in m.keys()` binds that pointer, so
// `k->copy()` and `(*k).copy()` copy the key; `k.copy()` copies the
// pointer (a pointer is a COPY type). A pointer to a pointer copies the
// pointer it points at through `->`.
fn main() -> i32 {
    var m: {string: i32}
    m.insert("ab", 1)
    var names: [string]
    for *k in m.keys() {
        names.push(k->copy())
        names.push((*k).copy())
        var q: *const string = k.copy()
        names.push(q->copy())
    }

    var s: i64 = 5
    var p: *const i64 = const &s
    var pp: *const *const i64 = const &p
    var a: *const i64 = pp->copy()
    var c: i64 = p->copy()
    if *a + c != 10 { return 1 }

    var total: usize = 0
    for const *n in names {
        total += n->size()
    }

    return (total as i32) - 6
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
