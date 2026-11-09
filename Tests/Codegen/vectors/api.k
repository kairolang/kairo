// Every member of `[T]` (Lib/builtin/containers/vector.k) on a trivially
// copyable element: the API Compiler/ uses of Stage 0's vec
//, plus `push` (collections.mdx) and the
// `[T;]` view. Each check returns its own exit code, so a failure names
// itself; 0 is a pass.

fn sum(const s: [i32;]) -> i32 {
    var t: i32 = 0
    var i: usize = 0
    while i < s.len { t += s[i]; i += 1 }
    return t
}

fn read_const(const v: [i32], i: usize) -> i32 { return v[i] }

fn main() -> i32 {
    // default ctor, empty, size
    var e: [i32]
    if !e.empty() { return 1 }
    if e.size() != 0 { return 2 }
    if e.capacity() != 0 { return 3 }

    // list literal, [] read and write, const []
    var v: [i32] = [10, 20, 30]
    if v.size() != 3 { return 4 }
    if v[1] != 20 { return 5 }
    v[1] = 21
    v[2] += 5
    if read_const(v, 1) != 21 { return 6 }
    if v[2] != 35 { return 7 }

    // push_back of an lvalue (kept) and of a temporary; push; growth
    var x: i32 = 40
    v.push_back(x)
    v.push_back(x + 10)
    v.push(60)
    if (v.size() != 6) || (x != 40) { return 8 }
    if v[5] != 60 { return 9 }

    // front, back, data, begin, end
    if *v.front() != 10 { return 10 }
    if *v.back() != 60 { return 11 }
    if v.data()[3] != 40 { return 12 }
    var n: usize = 0
    unsafe { n = ((v.end() as usize) - (v.begin() as usize)) / 4 }
    if n != 6 { return 13 }
    *v.back() = 61

    // pop_back, the slice view
    v.pop_back()
    if v.size() != 5 { return 14 }
    if sum(v) != 10 + 21 + 35 + 40 + 50 { return 15 }

    // copy ctor and assignment: independent storage
    var c = v
    c[0] = 99
    if v[0] != 10 { return 16 }
    var d: [i32]
    d = v
    d.push_back(7)
    if (v.size() != 5) || (d.size() != 6) { return 17 }
    d = c
    if (d[0] != 99) || (d.size() != 5) { return 18 }
    d = d
    if d[4] != 50 { return 19 }

    // reserve keeps the elements; capacity never shrinks
    v.reserve(100)
    if (v.capacity() < 100) || (v[4] != 50) { return 20 }
    v.reserve(1)
    if v.capacity() < 100 { return 21 }

    // insert at the front, in the middle and at the end
    var w: [i32] = [1, 2, 4]
    w.insert(w.begin(), 0)
    var *at = w.begin()
    unsafe { at = w.begin() + 3 }
    w.insert(at, 3)
    w.insert(w.end(), 5)
    var i: usize = 0
    while i < w.size() { if w[i] != (i as i32) { return 22 }; i += 1 }

    // erase one, then a range
    unsafe { w.erase(w.begin() + 2) }            // 0 1 3 4 5
    if (w.size() != 5) || (w[2] != 3) { return 23 }
    unsafe { w.erase(w.begin() + 1, w.begin() + 3) }  // 0 4 5
    if (w.size() != 3) || (w[1] != 4) || (w[2] != 5) { return 24 }
    w.erase(w.begin(), w.begin())                 // nothing
    if w.size() != 3 { return 25 }

    // emplace_back returns the new element
    var *p = w.emplace_back(8)
    *p += 1
    if w[3] != 9 { return 26 }

    // ctor(n) and resize: default elements are zero
    var z = Vector<i32>(4usize)
    if (z.size() != 4) || (z[3] != 0) { return 27 }
    z.resize(6)
    if (z.size() != 6) || (z[5] != 0) { return 28 }
    z.resize(2)
    if z.size() != 2 { return 29 }
    z.resize(4, 7)
    if (z[2] != 7) || (z[3] != 7) || (z[1] != 0) { return 30 }

    // clear keeps the storage
    var cap = z.capacity()
    z.clear()
    if (!z.empty()) || (z.capacity() != cap) { return 31 }

    // for, and for *x writing through
    var t: i32 = 0
    for y in w { t += y }
    if t != 0 + 4 + 5 + 9 { return 32 }
    for *y in w { *y *= 2 }
    if w[3] != 18 { return 33 }

    // a slice converted to a vector copies
    var s: [i32;] = [5, 6]
    var sv = s as [i32]
    sv[0] = 0
    if s[0] != 5 { return 34 }

    // an empty list literal
    var none: [i32] = []
    if !none.empty() { return 35 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
