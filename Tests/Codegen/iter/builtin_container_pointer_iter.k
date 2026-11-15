// The builtin containers iterate through pointer yields:
//   [T]      op in (self) -> yield *T, op in (const self) -> yield *const T
//   {T}      op in (const self) -> yield *const T
//   {K: V}   op in (self) -> yield (*const K, *V),
//            op in (const self) -> yield (*const K, *const V)
// `for x in v` copies, `for *x in v` writes the element, `for (k, *v) in m`
// writes the stored value, a const container iterates, and a `const`
// binder reads a mutable vector through the const form.

fn sum_const(const v: [i32]) -> i32 {
    var s = 0
    for x in v {
        s += x
    }

    for const *x in v {
        s += *x
    }

    return s
}

fn sum_map(const m: {i32: i32}) -> i32 {
    var s = 0
    for (k, v) in m {
        s += k * v
    }

    for (const *k, const *v) in m {
        s += *k * *v
    }

    return s
}

fn sum_set(const st: {i32}) -> i32 {
    var s = 0
    for x in st {
        s += x
    }

    for const *x in st {
        s += *x
    }

    return s
}

fn main() -> i32 {
    var v: [i32] = [1, 2, 3]
    for *x in v {
        *x += 10
    }

    // v is 11, 12, 13.
    for x in v {
        x += 100 // a copy: v is unchanged
        if x < 100 {
            return 1
        }
    }

    if v[0] != 11 || v[2] != 13 {
        return 2
    }

    var cs = 0
    for const x in v {
        cs += x
    }

    for const *x in v {
        cs += *x
    }

    if cs != 72 || sum_const(v) != 72 {
        return 3
    }

    var m: {i32: i32} = {1: 2, 3: 4}
    for (k, *w) in m {
        *w = *w * 10 + k
    }

    // m is {1: 21, 3: 43}.
    if m[1] != 21 || m[3] != 43 {
        return 4
    }

    for (k, w) in m {
        // DIAG: builtin_container_pointer_iter.k:[[@LINE+1]]:9: warning [SC275W]: this writes to a copy of the element
        w = 0
        if k == 0 {
            return 5
        }
    }

    if sum_map(m) != 2 * (21 + 129) {
        return 6
    }

    var st: {i32} = {5, 6}
    if sum_set(st) != 22 {
        return 7
    }

    var n = 0
    for x in st {
        n += x
    }

    for _ in m {
        n += 100
    }

    return n - 200 // 11
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error --implicit-check-not=warning
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty --implicit-check-not=error
// BUILD-NOT: C307W
// RUN: %t.exe; test $? -eq 11
