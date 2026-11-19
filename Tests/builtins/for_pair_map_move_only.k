// `string` and `[i32]` are MOVE types in this library, and `{K: V}`'s
// `op in` yields `(*const K, *const V)`: `for (const *k, const *v) in m`
// reads each entry in place, and `for (k, v) in m` would copy each key and
// value, which is SC182E with `const *` as the fix
// (for_pair_map_copy_binders.k).
fn main() -> i32 {
    var m: {string: [i32]}
    m.insert("a", [1, 2])
    var n: usize = 0
    for (const *k, const *v) in m {
        n += k->size() + v->size()
    }

    return (n as i32) - 3
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
